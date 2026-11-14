import Foundation

/// Orchestrates a project's VM: create, start, run commands in it, tear down.
public struct Engine: Sendable {
    public let project: Project
    public let runtime: ContainerRuntime
    public var console: Console
    public let terminal: TerminalInfo
    /// Absolute path of the titan binary, baked into generated shims.
    public let titanExecutable: String
    /// When false (dry-run), nothing is written to disk.
    public let persist: Bool
    public let paths: TitanPaths
    /// Whether a host port is free (injectable so tests don't depend on what this Mac runs).
    let portIsFree: @Sendable (Int) -> Bool
    /// Folder with the in-VM port forwarder binary (nil: publish ports directly).
    public let forwarderDirectory: URL?

    public enum ForwarderSource: Sendable { case auto, at(URL), disabled }

    public init(project: Project, runtime: ContainerRuntime, console: Console,
                terminal: TerminalInfo = .current, titanExecutable: String, persist: Bool = true,
                paths: TitanPaths = .standard, portIsFree: @escaping @Sendable (Int) -> Bool = Ports.isFree,
                forwarder: ForwarderSource = .auto) {
        self.project = project
        self.runtime = runtime
        self.console = console
        self.terminal = terminal
        self.titanExecutable = titanExecutable
        self.persist = persist
        self.paths = paths
        self.portIsFree = portIsFree
        switch forwarder {
        case .auto: forwarderDirectory = Forwarder.shareDirectory(executable: titanExecutable)
        case .at(let url): forwarderDirectory = url
        case .disabled: forwarderDirectory = nil
        }
    }

    func save(_ state: ProjectState) throws { if persist { try state.save(project) } }

    var name: String { project.containerName }

    public func resolve() throws -> ResolvedEnvironment { try EnvironmentResolver.resolve(project) }

    func preflight() throws {
        guard runtime.isInstalled() else { throw TitanError.runtimeMissing }
        if !runtime.isSystemRunning() {
            console.step("Starting the container system service…")
            try runtime.startSystem()
        }
    }

    // MARK: up

    /// `bootstrap` runs once in a freshly created VM before postCreate (used by `titan new`
    /// to generate the project's code before `npm install` and friends).
    @discardableResult
    public func up(rebuild: Bool = false, bootstrap: [[String]] = []) throws -> ResolvedEnvironment {
        let env = try resolve()
        try preflight()
        var state = ProjectState.load(project) ?? ProjectState(containerName: name)
        var status = runtime.status(of: name)
        let drifted = state.configHash != nil && state.configHash != env.configHash
        console.debug("container \(name) is \(status.rawValue); drifted=\(drifted)")

        if status != .missing, rebuild || (drifted && status == .stopped) {
            console.step(rebuild ? "Removing old VM \(name)…" : "Config changed, recreating stopped VM…")
            try runtime.remove(name)
            status = .missing
        }
        // A stopped VM keeps its port forwards; if another VM or app took one meanwhile,
        // starting would fail, so recreate it with free ports instead.
        if status == .stopped {
            let busy = (state.ports ?? env.ports.map(PortMapping.same)).map(\.host).filter { !portIsFree($0) }
            if !busy.isEmpty {
                console.step("Port \(busy.map(String.init).joined(separator: ", ")) is now in use; recreating VM with free ports…")
                try runtime.remove(name)
                status = .missing
            }
        }

        // Services first: postCreate (migrations, seeds) may need the database.
        try upServices(env, state: &state, rebuild: rebuild)

        switch status {
        case .missing:
            var ports = try allocatePorts(env.ports, strict: env.strictPorts == true)
            var extraMounts = try mounts(for: env)
            if !ports.isEmpty {
                if let dir = forwarderDirectory {
                    ports = Forwarder.route(ports)
                    extraMounts.append(Mount(hostPath: dir.path, guestPath: Forwarder.guestDirectory, readOnly: true))
                } else {
                    console.warn("Port forwarder not found (\(Forwarder.binaryName)); apps listening only on 127.0.0.1 "
                                 + "won't be reachable from the Mac. Reinstall titan with `make install`.")
                }
            }
            let image = try prepareImage(env)
            console.step("Creating VM \(console.paint(name, "1")) from \(image)")
            try runtime.run(RunSpec(name: name, image: image, hostPath: project.root.path,
                                    guestPath: env.workspaceFolder, ports: ports,
                                    env: cacheEnvironment(env).merging(env.containerEnv) { _, user in user },
                                    cpus: env.cpus, memory: memory(for: env), mounts: extraMounts))
            let services = state.services
            state = ProjectState(containerName: name)
            state.services = services
            state.configHash = env.configHash
            state.image = image
            state.ports = ports
            try save(state)  // persist early so a failing postCreate resumes next time
            startForwarder(state.ports)
            try writeServiceHosts(env)
            try runLifecycle(bootstrap, phase: "generate", env: env)
            try finishPostCreate(env, state: &state)
            try runLifecycle(env.postStart, phase: "postStart", env: env)
        case .stopped:
            console.step("Starting VM \(name)")
            try runtime.start(name)
            startForwarder(state.ports)
            try writeServiceHosts(env)
            try finishPostCreate(env, state: &state)
            try runLifecycle(env.postStart, phase: "postStart", env: env)
        case .running:
            if drifted {
                console.warn("Environment config changed since this VM was created. Run `titan rebuild` to apply it.")
            }
            startForwarder(state.ports)  // idempotent: a running forwarder keeps its ports
            try writeServiceHosts(env)
            try finishPostCreate(env, state: &state)
        }

        try save(state)
        if persist {
            try ShimWriter.write(project: project, commands: env.shims, titan: titanExecutable)
            var registry = Registry.load(paths)
            registry.record(project, image: state.image)
            for svc in (state.services ?? [:]).values.sorted(by: { $0.image < $1.image }) { registry.record(project, image: svc.image) }
            try? registry.save(paths)  // only feeds `titan gc`; never fail `up` over it
        }
        return env
    }

    // MARK: ports

    /// Host ports to publish: the configured port when free, else the next free one
    /// above it (unless strictPorts). The app in the VM always sees the configured port.
    func allocatePorts(_ guests: [Int], strict: Bool, label: String? = nil) throws -> [PortMapping] {
        var taken = Set<Int>()
        var result: [PortMapping] = []
        var busy: [Int] = []
        for guest in guests {
            if !taken.contains(guest), portIsFree(guest) {
                result.append(.same(guest)); taken.insert(guest); continue
            }
            busy.append(guest)
            guard !strict,
                  let host = (guest + 1...min(guest + 100, 65535)).first(where: { !taken.contains($0) && portIsFree($0) })
            else { throw TitanError.portsInUse([guest]) }
            console.warn("Port \(guest) is busy on this Mac; forwarding localhost:\(host) → \(guest) in \(label ?? "the VM").")
            result.append(PortMapping(host: host, guest: guest)); taken.insert(host)
        }
        return result
    }

    /// Starts the in-VM forwarder for ports that go through it. A second copy exits
    /// immediately when the first already holds the ports, so calling this is always safe.
    func startForwarder(_ ports: [PortMapping]?) {
        guard let ports, ports.contains(where: { $0.via != nil }) else { return }
        let spec = ExecSpec(name: name, command: Forwarder.command(for: ports), workdir: nil, env: [:],
                            interactive: false, tty: false, detach: true)
        if let code = try? runtime.exec(spec), code != 0 {
            console.warn("Couldn't start the port forwarder (exit \(code)); localhost URLs may not work.")
        }
    }

    /// What `localhost` URLs reach this project's VM.
    public func publishedPorts(_ env: ResolvedEnvironment) -> [PortMapping] {
        ProjectState.load(project)?.ports ?? env.ports.map(PortMapping.same)
    }

    /// Whether the app in the VM is listening on `guestPort`.
    public func isListening(guestPort: Int, env: ResolvedEnvironment) -> Bool {
        let spec = ExecSpec(name: name, command: Tunnel.listenProbe(guestPort), workdir: nil, env: [:],
                            interactive: false, tty: false)
        return (try? runtime.exec(spec)) == 0
    }

    /// Writes the project's command shims without touching the VM (shell hook, on `cd`).
    /// Returns the shimmed commands.
    @discardableResult
    public func activate() throws -> [String] {
        let env = try resolve()
        if persist { try ShimWriter.write(project: project, commands: env.shims, titan: titanExecutable) }
        return env.shims
    }

    /// Brings the VM up if needed and returns its environment (for commands like `share`).
    public func ensureUp() throws -> ResolvedEnvironment { try ensureRunning() }

    // MARK: shared cache

    /// Cache variables, minus any the project's containerEnv sets itself.
    func cacheEnvironment(_ env: ResolvedEnvironment) -> [String: String] {
        guard env.sharedCache else { return [:] }
        return SharedCache.environment.filter { env.containerEnv[$0.key] == nil }
    }

    func mounts(for env: ResolvedEnvironment) throws -> [Mount] {
        guard env.sharedCache else { return [] }
        if persist {
            for tool in SharedCache.tools {
                try FileManager.default.createDirectory(at: paths.sharedCache.appendingPathComponent(tool.subdirectory),
                                                        withIntermediateDirectories: true)
            }
        }
        return [Mount(hostPath: paths.sharedCache.path, guestPath: SharedCache.guestPath)]
    }

    /// Environment for commands run in the VM: cache variables, then the project's remoteEnv.
    func execEnvironment(_ env: ResolvedEnvironment) -> [String: String] {
        cacheEnvironment(env).merging(serviceEnvironment(env)) { _, svc in svc }.merging(env.remoteEnv) { _, user in user }
    }

    func finishPostCreate(_ env: ResolvedEnvironment, state: inout ProjectState) throws {
        guard let hash = state.configHash, state.postCreateHash != hash else { return }
        try runLifecycle(env.postCreate, phase: "postCreate", env: env)
        state.postCreateHash = hash
        try save(state)
    }

    func prepareImage(_ env: ResolvedEnvironment) throws -> String {
        switch env.image {
        case .pull(let ref):
            if let lock = Lockfile.load(project), lock.image == ref, lock.digest != nil {
                console.step("Pulling \(ref) (pinned by titan.lock)")
                try runtime.pull(lock.pinnedReference)
                return lock.pinnedReference
            }
            console.step("Pulling \(ref)")
            try runtime.pull(ref)
            if let digest = runtime.imageDigest(ref) {
                // Keep service pins that may already be in the lockfile.
                let lock = Lockfile(image: ref, digest: digest, services: Lockfile.load(project)?.services)
                if persist { try lock.save(project) }
                console.debug("locked \(ref) → \(digest)")
            } else {
                console.debug("could not read a digest for \(ref); titan.lock not written")
            }
            return ref
        case .build(let dockerfile, let context, let args, _):
            let tag = "titan-local/\(project.slug):\(env.configHash.prefix(12))"
            console.step("Building \(dockerfile)")
            try runtime.build(tag: tag, dockerfile: dockerfile, context: context, args: args)
            return tag
        }
    }

    func runLifecycle(_ steps: [[String]], phase: String, env: ResolvedEnvironment) throws {
        for step in steps {
            let display = step.starts(with: ["/bin/sh", "-c"]) ? step[2] : shellJoin(step)
            console.step("\(phase): \(display)")
            let code = try runtime.exec(ExecSpec(name: name, command: step, workdir: env.workspaceFolder,
                                                 env: execEnvironment(env), interactive: false, tty: terminal.stdoutIsTTY))
            guard code == 0 else { throw TitanError.lifecycleFailed(phase, code) }
        }
    }

    // MARK: run / shell

    /// Brings the VM up if needed. Fast path when it is already running.
    /// `announce` (for quiet shim runs) shows setup progress only when setup actually happens.
    func ensureRunning(announce: Console? = nil) throws -> ResolvedEnvironment {
        let env = try resolve()
        if runtime.status(of: name) == .running, ProjectState.load(project)?.configHash != nil {
            return env
        }
        guard let announce else { return try up() }
        var loud = self
        loud.console = announce
        let fresh = ProjectState.load(project)?.configHash == nil
        announce.step(fresh ? "Setting up \(announce.paint(project.name, "1")) (first run; later runs start instantly)…"
                            : "Starting \(project.name)'s VM…")
        let result = try loud.up()
        announce.success("\(project.name) is ready")
        return result
    }

    public func execSpec(command: [String], cwd: String, env: ResolvedEnvironment) -> ExecSpec {
        let workdir = project.guestPath(forHost: cwd, workspaceFolder: env.workspaceFolder) ?? env.workspaceFolder
        var vars = execEnvironment(env)
        let host = ProcessInfo.processInfo.environment
        for key in ["TERM", "COLORTERM", "LANG"] where vars[key] == nil {
            if let v = host[key] { vars[key] = v }
        }
        return ExecSpec(name: name,
                        command: command.map { project.translateArgument($0, workspaceFolder: env.workspaceFolder) },
                        workdir: workdir, env: vars,
                        interactive: true,
                        tty: terminal.stdinIsTTY && terminal.stdoutIsTTY)
    }

    public func run(_ command: [String], cwd: String = FileManager.default.currentDirectoryPath,
                    announce: Console? = nil) throws -> Never {
        guard !command.isEmpty else { throw TitanError.emptyCommand }
        let env = try ensureRunning(announce: announce)
        try runtime.execReplacingProcess(execSpec(command: command, cwd: cwd, env: env))
    }

    public static let loginShell = ["/bin/sh", "-c",
                                    "if command -v bash >/dev/null 2>&1; then exec bash -l; else exec sh -l; fi"]

    public func shell(cwd: String = FileManager.default.currentDirectoryPath) throws -> Never {
        let env = try ensureRunning()
        var spec = execSpec(command: Engine.loginShell, cwd: cwd, env: env)
        spec.env["TITAN_PROJECT"] = project.name
        try runtime.execReplacingProcess(spec)
    }

    // MARK: down / status

    /// Stops (or with `remove`, deletes) the app VM and its services. Service data
    /// volumes are kept unless `volumes` is set.
    public func down(remove: Bool, volumes: Bool = false) throws {
        guard runtime.isInstalled() else { throw TitanError.runtimeMissing }
        try downServices(try? resolve(), remove: remove, volumes: volumes)
        switch runtime.status(of: name) {
        case .missing:
            console.info("No VM for this project.")
        case .running where !remove:
            try runtime.stop(name)
            console.success("Stopped \(name)")
        default:
            if remove {
                try runtime.remove(name)
                if persist { try? FileManager.default.removeItem(at: ProjectState.url(project)) }
                console.success("Removed \(name)")
            } else {
                console.info("\(name) is already stopped.")
            }
        }
    }

    /// Memory a new VM gets: the config's value, else half the Mac's RAM (max 8 GiB).
    public func memory(for env: ResolvedEnvironment) -> String { env.memory ?? Resources.defaultMemory() }

    public struct StatusReport: Sendable {
        public var project: Project
        public var containerName: String
        public var status: ContainerStatus
        public var environment: ResolvedEnvironment?
        public var environmentError: String?
        public var drifted: Bool
        public var lock: Lockfile?
        /// What the existing VM was created with (nil when it doesn't exist).
        public var resources: VMResources?
        /// Memory a VM created now would get.
        public var plannedMemory: String?
    }

    public func status() -> StatusReport {
        var env: ResolvedEnvironment?
        var envError: String?
        do { env = try resolve() } catch { envError = "\(error)" }
        let state = ProjectState.load(project)
        let drifted = env.map { e in state?.configHash.map { $0 != e.configHash } ?? false } ?? false
        let status = runtime.isInstalled() ? runtime.status(of: name) : .missing
        return StatusReport(project: project, containerName: name, status: status,
                            environment: env, environmentError: envError, drifted: drifted,
                            lock: Lockfile.load(project),
                            resources: status == .missing ? nil : runtime.resources(of: name),
                            plannedMemory: env.map(memory(for:)))
    }

    // MARK: stats

    public struct StatsReport: Sendable {
        public var containerName: String
        public var cpuPercent: Double
        public var sample: VMStats
        public var resources: VMResources?
        public var imageSizeBytes: UInt64?
        public var imageStore: ImageStoreUsage?
    }

    /// Takes two samples `interval` apart so CPU is a real rate, not a single noisy reading.
    public func stats(interval: TimeInterval = 1) throws -> StatsReport {
        guard runtime.isInstalled() else { throw TitanError.runtimeMissing }
        guard runtime.status(of: name) == .running else {
            throw TitanError.message("VM \(name) is not running. Start it with `titan up`.")
        }
        guard let first = runtime.stats(of: name) else {
            throw TitanError.message("\(runtime.displayName) did not report stats for \(name).")
        }
        let start = Date()
        if interval > 0 { Thread.sleep(forTimeInterval: interval) }
        let second = runtime.stats(of: name) ?? first
        let elapsed = Date().timeIntervalSince(start)
        let res = runtime.resources(of: name)
        return StatsReport(containerName: name,
                           cpuPercent: Resources.cpuPercent(first, second, interval: elapsed),
                           sample: second, resources: res,
                           imageSizeBytes: res?.imageDigest.flatMap(runtime.imageSize(digest:)),
                           imageStore: runtime.imageStoreUsage())
    }
}
