import Foundation

/// Orchestrates a project's VM: create, start, run commands in it, tear down.
public struct Engine: Sendable {
    public let project: Project
    public let runtime: ContainerRuntime
    public let console: Console
    public let terminal: TerminalInfo
    /// Absolute path of the titan binary, baked into generated shims.
    public let titanExecutable: String
    /// When false (dry-run), nothing is written to disk.
    public let persist: Bool
    public let paths: TitanPaths

    public init(project: Project, runtime: ContainerRuntime, console: Console,
                terminal: TerminalInfo = .current, titanExecutable: String, persist: Bool = true,
                paths: TitanPaths = .standard) {
        self.project = project
        self.runtime = runtime
        self.console = console
        self.terminal = terminal
        self.titanExecutable = titanExecutable
        self.persist = persist
        self.paths = paths
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

    @discardableResult
    public func up(rebuild: Bool = false) throws -> ResolvedEnvironment {
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

        switch status {
        case .missing:
            let busy = env.ports.filter { !Ports.isFree($0) }
            guard busy.isEmpty else { throw TitanError.portsInUse(busy) }
            let image = try prepareImage(env)
            console.step("Creating VM \(console.paint(name, "1")) from \(image)")
            try runtime.run(RunSpec(name: name, image: image, hostPath: project.root.path,
                                    guestPath: env.workspaceFolder, ports: env.ports,
                                    env: cacheEnvironment(env).merging(env.containerEnv) { _, user in user },
                                    cpus: env.cpus, memory: memory(for: env), mounts: try mounts(for: env)))
            state = ProjectState(containerName: name)
            state.configHash = env.configHash
            state.image = image
            try save(state)  // persist early so a failing postCreate resumes next time
            try finishPostCreate(env, state: &state)
            try runLifecycle(env.postStart, phase: "postStart", env: env)
        case .stopped:
            console.step("Starting VM \(name)")
            try runtime.start(name)
            try finishPostCreate(env, state: &state)
            try runLifecycle(env.postStart, phase: "postStart", env: env)
        case .running:
            if drifted {
                console.warn("Environment config changed since this VM was created. Run `titan rebuild` to apply it.")
            }
            try finishPostCreate(env, state: &state)
        }

        try save(state)
        if persist {
            try ShimWriter.write(project: project, commands: env.shims, titan: titanExecutable)
            var registry = Registry.load(paths)
            registry.record(project, image: state.image)
            try? registry.save(paths)  // only feeds `titan gc`; never fail `up` over it
        }
        return env
    }

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
        cacheEnvironment(env).merging(env.remoteEnv) { _, user in user }
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
                if persist { try Lockfile(image: ref, digest: digest).save(project) }
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
    func ensureRunning() throws -> ResolvedEnvironment {
        let env = try resolve()
        if runtime.status(of: name) == .running, ProjectState.load(project)?.configHash != nil {
            return env
        }
        return try up()
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

    public func run(_ command: [String], cwd: String = FileManager.default.currentDirectoryPath) throws -> Never {
        guard !command.isEmpty else { throw TitanError.emptyCommand }
        let env = try ensureRunning()
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

    public func down(remove: Bool) throws {
        guard runtime.isInstalled() else { throw TitanError.runtimeMissing }
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
