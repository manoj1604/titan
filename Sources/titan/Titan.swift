import ArgumentParser
import Foundation
import TitanCore

@main
struct Titan: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "titan",
        abstract: "Reproducible per-project Linux dev environments on your Mac, in lightweight VMs.",
        discussion: """
        Every project gets its own Linux VM, defined by a standard devcontainer.json and pinned by titan.lock, so "works on my machine" means works on every machine. Your editor and files stay on the Mac; commands run in the VM.

        Get started:
          titan setup              get this Mac ready (once)
          titan new shop -t vite   new project: VM, starter code, ready to run
          cd my-repo && npm test   in a Titan project, commands run in its VM

        Docs: https://github.com/manoj1604/titan
        """,
        version: TitanVersion.current,
        groupedSubcommands: [
            CommandGroup(name: "Get started", subcommands: [Setup.self, New.self, Init.self]),
            CommandGroup(name: "Work in a project", subcommands: [Up.self, Run.self, Shell.self, Down.self, Rebuild.self]),
            CommandGroup(name: "Services and sharing", subcommands: [Add.self, Share.self]),
            CommandGroup(name: "See what's running", subcommands: [Status.self, Ps.self, Stats.self, Logs.self]),
            CommandGroup(name: "Maintenance", subcommands: [Doctor.self, Lock.self, GC.self, Cache.self]),
            CommandGroup(name: "Integrations", subcommands: [Agents.self, VSCode.self, Hook.self, Activate.self, Relay.self]),
        ])

    /// Accept git-style global options before the subcommand (`titan -C dir up`).
    static func main() {
        // Line-buffer stdout so it interleaves correctly with progress on stderr, even when
        // piped (plans, checklists and links must appear in order, not at exit).
        setvbuf(stdout, nil, _IOLBF, 0)
        main(hoistGlobalOptions(Array(CommandLine.arguments.dropFirst())))
    }

    static func hoistGlobalOptions(_ args: [String]) -> [String] {
        var globals: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if (a == "-C" || a == "--directory"), i + 1 < args.count {
                globals += [a, args[i + 1]]; i += 2
            } else if a.hasPrefix("--directory=") || ["-v", "--verbose", "--dry-run"].contains(a) {
                globals.append(a); i += 1
            } else {
                break
            }
        }
        guard !globals.isEmpty, i < args.count else { return args }
        return [args[i]] + globals + Array(args[(i + 1)...])  // Array(): older compilers reject slice concatenation
    }
}

struct GlobalOptions: ParsableArguments {
    @Option(name: [.customShort("C"), .customLong("directory")], help: "Run as if titan was started in <dir>.")
    var directory: String?

    @Flag(name: .shortAndLong, help: "Show debug output.")
    var verbose = false

    @Flag(name: .customLong("dry-run"), help: "Print the container commands instead of running them.")
    var dryRun = false

    var cwd: String {
        guard let directory else { return FileManager.default.currentDirectoryPath }
        return URL(fileURLWithPath: directory, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }

    func console(quiet: Bool = false) -> Console { Console(verbose: verbose, quiet: quiet) }

    func engine(quiet: Bool = false, project: Project? = nil) -> Engine {
        let console = console(quiet: quiet)
        let runner: CommandRunner = dryRun ? DryRunRunner(console: Console(verbose: verbose)) : ProcessRunner()
        var engine = Engine(project: project ?? Project.discover(from: URL(fileURLWithPath: cwd)),
                            runtime: AppleContainerRuntime(runner: runner),
                            console: console,
                            titanExecutable: titanExecutablePath,
                            persist: !dryRun)
        if !dryRun { engine.onRunning = { project, _ in startFileRelay(project) } }
        return engine
    }
}

/// How to reach titan again later (baked into shims and the shell hook): the path it was
/// invoked through, *without* resolving symlinks. Homebrew runs it from a versioned Cellar
/// folder that `brew upgrade` deletes, but the /opt/homebrew/bin/titan link stays valid.
var titanExecutablePath: String {
    ExecutablePath.stable(argv0: CommandLine.arguments[0], path: ProcessInfo.processInfo.environment["PATH"] ?? "",
                         fallback: Bundle.main.executableURL?.path ?? CommandLine.arguments[0])
}


/// Prints Titan errors nicely instead of ArgumentParser's default dump.
@discardableResult
func guarded<T>(_ console: Console, _ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as TitanError {
        console.error(error.description)
        throw ExitCode.failure
    }
}

// MARK: - Commands

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write a .devcontainer/devcontainer.json detected from this project.")

    @OptionGroup var global: GlobalOptions
    @Flag(help: "Overwrite an existing devcontainer.json.") var force = false
    @Flag(name: .customLong("print"), help: "Print the config instead of writing it.") var printOnly = false

    func run() throws {
        let console = global.console()
        let project = Project.discover(from: URL(fileURLWithPath: global.cwd))
        let text = EnvironmentResolver.generateDevcontainer(for: project)
        if printOnly { print(text, terminator: ""); return }
        defer { ensureShellHook(console, dryRun: global.dryRun) }

        if let existing = project.devcontainerURL, !force {
            console.warn("\(existing.path) already exists (use --force to overwrite).")
            throw ExitCode.failure
        }
        let url = project.root.appendingPathComponent(".devcontainer/devcontainer.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        console.success("Wrote \(url.path)")
        let engine = global.engine(project: Project(root: project.root))
        if let env = try? engine.resolve() { writeAgentNotes(engine: engine, env: env, ask: true, console: console) }
        console.info("  Next: titan up")
    }
}

struct New: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a new project: folder, environment, VM and starter code, in one step.",
        discussion: """
        Shows what will be downloaded first, then creates the folder, git repo, devcontainer.json and titan.lock, starts the VM and runs the framework's own generator inside it, so nothing (Node, Python, …) has to be installed on the Mac. With the shell hook, your terminal moves into the new project.

        Templates: \(ProjectTemplate.all.map(\.id).joined(separator: ", "))

        Examples:
          titan new shop -t vite --with postgres
          titan new api -t fastapi
          titan new .    (existing code: detected, not generated)
        """)
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Folder to create (or `.` for the current folder).") var name: String
    @Option(name: [.short, .long], help: "Starter: \(ProjectTemplate.all.map(\.id).joined(separator: ", ")).") var template: String?
    @Option(name: .long, parsing: .upToNextOption, help: "Services, e.g. --with postgres redis.") var with: [String] = []
    @Option(name: .customLong("runtime-version"), help: "Override the runtime version (e.g. 20 for Node, 3.13 for Python).") var runtimeVersion: String?
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false
    @Flag(help: "Use the runtime's full image instead of the shared toolchain store.") var fullImage = false

    func run() throws {
        let c = global.console()
        defer { ensureShellHook(c, dryRun: global.dryRun) }
        try guarded(c) {
            let cwd = URL(fileURLWithPath: global.cwd)
            let here = name == "."
            let folder = here ? cwd : cwd.appendingPathComponent(name)
            let projectName = folder.lastPathComponent
            let services = with.flatMap { $0.split(separator: ",").map(String.init) }

            let fm = FileManager.default
            let contents = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { ![".git", ".DS_Store"].contains($0) }
            if here, !contents.isEmpty {
                // Existing code: detect instead of generating over it.
                guard template == nil else {
                    throw TitanError.message("This folder already has files; a starter would overwrite them. "
                                             + "Run `titan new .` without --template to set up the existing code.")
                }
                try adoptExisting(folder: folder, services: services, console: c)
                return
            }
            if !here { try NewProjectPlan.validate(name: projectName) }
            if !here, fm.fileExists(atPath: folder.path), !contents.isEmpty {
                throw TitanError.message("\(folder.path) already exists and isn't empty.")
            }

            let chosen = try template.map { id -> ProjectTemplate in
                guard let t = ProjectTemplate.find(id) else {
                    throw TitanError.message("Unknown template '\(id)'. Choose one of: \(ProjectTemplate.all.map(\.id).joined(separator: ", ")).")
                }
                return t
            } ?? pickTemplate(console: c)

            let runtime = AppleContainerRuntime(runner: ProcessRunner())
            let plan = try NewProjectPlan.make(name: projectName, folder: folder, template: chosen, runtimeVersion: runtimeVersion,
                                               services: services, localImages: runtime.listImages() ?? [],
                                               localVolumes: runtime.listVolumes() ?? [], useToolchainStore: !fullImage)
            let diskOK = printPlan(plan, console: c)
            fflush(stdout)  // show the plan before progress (stderr) starts
            if !diskOK, !global.dryRun {
                throw TitanError.message("Not enough free disk for the downloads. Free space (e.g. `titan gc`) and try again.")
            }
            if global.dryRun { print(c.paint("--dry-run: nothing created.", "2")); return }
            guard confirm("Create \(projectName)?", yes: yes || isatty(0) != 1, console: c) else { return }

            try fm.createDirectory(at: folder.appendingPathComponent(".devcontainer"), withIntermediateDirectories: true)
            try Data(plan.devcontainer().utf8).write(to: folder.appendingPathComponent(".devcontainer/devcontainer.json"))
            initGit(folder)

            let engine = Engine(project: Project(root: folder), runtime: runtime, console: c,
                                titanExecutable: titanExecutablePath)
            let env = try engine.resolve()
            do {
                try engine.up(bootstrap: [["/bin/sh", "-c", plan.generationScript(workspace: env.workspaceFolder)]])
            } catch {
                c.error("Setup stopped. The folder is kept: fix the problem and run `titan up` in \(folder.path).")
                throw error
            }
            finish(plan: plan, engine: engine, env: env, console: c)
            writeAgentNotes(engine: engine, env: env, ask: false, console: c)
        }
    }

    func pickTemplate(console c: Console) throws -> ProjectTemplate {
        guard isatty(0) == 1 else {
            throw TitanError.message("Choose a starter with --template (\(ProjectTemplate.all.map(\.id).joined(separator: ", "))).")
        }
        print("What are you building?")
        for (i, t) in ProjectTemplate.all.enumerated() {
            print("  \(c.paint(String(i + 1), "1")). \(t.id.padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.paint(t.summary, "2"))")
        }
        print("Choose [1]: ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        if answer.isEmpty { return ProjectTemplate.all[0] }
        if let n = Int(answer), (1...ProjectTemplate.all.count).contains(n) { return ProjectTemplate.all[n - 1] }
        if let t = ProjectTemplate.find(answer) { return t }
        throw TitanError.message("'\(answer)' isn't one of the choices.")
    }

    /// Prints the plan; returns false when the disk clearly can't hold the downloads.
    @discardableResult
    func printPlan(_ plan: NewProjectPlan, console c: Console) -> Bool {
        print("\n  " + c.paint(plan.name, "1") + c.paint("  (\(plan.template.summary))", "2"))
        for item in plan.items {
            let where_ = item.cached ? c.paint("on this Mac", "32") : "↓ ~\(item.approxDownloadMB) MB"
            print("  \(item.role.padding(toLength: 9, withPad: " ", startingAt: 0)) \(item.label.padding(toLength: 15, withPad: " ", startingAt: 0)) "
                  + c.paint(item.image.padding(toLength: 24, withPad: " ", startingAt: 0), "2") + " \(where_)")
        }
        if plan.services.isEmpty { print(c.paint("  database  none (add later: titan add postgres)", "2")) }
        let free = (try? plan.folder.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage)
            .flatMap { $0 }.map { UInt64($0) }
        if plan.neededBytes > 0, let free {
            let ok = free > plan.neededBytes + (1 << 30)
            print("  disk      ~\(Resources.formatBytes(plan.neededBytes)) needed, \(Resources.formatBytes(free)) free "
                  + (ok ? c.paint("✓", "32") : c.paint("✗ low — free space first (`titan gc`)", "31")))
            print("")
            return free > plan.neededBytes
        }
        print("")
        return true
    }

    func initGit(_ folder: URL) {
        guard ProcessRunner().which("git") != nil,
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) else { return }
        // Don't nest a repo inside an existing one.
        if let r = try? ProcessRunner().capture(["git", "-C", folder.path, "rev-parse", "--is-inside-work-tree"]), r.ok { return }
        _ = try? ProcessRunner().capture(["git", "-C", folder.path, "init", "-q"])
    }

    func finish(plan: NewProjectPlan, engine: Engine, env: ResolvedEnvironment, console c: Console) {
        let url = engine.publishedPorts(env).first.map { "http://localhost:\($0.host)" }
        c.success("\(plan.name) is ready" + (url.map { " → \($0)" } ?? ""))
        let cdNeeded = plan.folder.path != FileManager.default.currentDirectoryPath
        if cdNeeded, let file = ProcessInfo.processInfo.environment["TITAN_CD_FILE"], !file.isEmpty {
            try? Data(plan.folder.path.utf8).write(to: URL(fileURLWithPath: file))  // the shell hook cds there
            c.info("  Next: \(plan.template.devCommand)")
        } else {
            c.info("  Next: " + (cdNeeded ? "cd \(plan.name) && " : "") + plan.template.devCommand)
        }
    }

    /// `titan new .` in a folder with code: write a detected devcontainer.json and bring it up.
    func adoptExisting(folder: URL, services: [String], console c: Console) throws {
        let project = Project(root: folder)
        if project.devcontainerURL == nil {
            let url = folder.appendingPathComponent(".devcontainer/devcontainer.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(EnvironmentResolver.generateDevcontainer(for: project, services: services).utf8).write(to: url)
            c.success("Detected \(StackDetector.detect(at: folder).kind); wrote \(url.path)")
        } else if !services.isEmpty {
            c.warn("devcontainer.json already exists; add services with `titan add \(services.joined(separator: " "))`.")
        }
        if global.dryRun { return }
        let engine = Engine(project: project, runtime: AppleContainerRuntime(runner: ProcessRunner()), console: c,
                            titanExecutable: titanExecutablePath)
        let env = try engine.up()
        let url = engine.publishedPorts(env).first.map { " → http://localhost:\($0.host)" } ?? ""
        c.success("\(project.name) is ready\(url)")
        writeAgentNotes(engine: engine, env: env, ask: true, console: c)
    }
}

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add services (postgres, redis, or any image) to this project.",
        discussion: """
        Each service runs in its own VM, reachable from the app by its name (e.g. `postgres`), with its data on a volume that survives `titan rebuild`. Presets set DATABASE_URL / REDIS_URL for the app.

        Examples:
          titan add postgres redis
          titan add postgres:15
        """)
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Presets (postgres, redis) or images.") var services: [String]

    func run() throws {
        let c = global.console()
        let project = Project.discover(from: URL(fileURLWithPath: global.cwd))
        try guarded(c) {
            for s in services {
                _ = try ResolvedService.resolve(name: ServicePreset.defaultName(for: s), config: ServiceConfig(image: s))
                if ServicePreset.find(image: s) == nil {
                    c.warn("\(s) has no preset: set its port/env/data in devcontainer.json (see README).")
                }
            }
            if let existing = project.devcontainerURL {
                // Rewriting JSONC would drop comments and reorder keys, so show the edit instead.
                let list = services.map { "\"\($0)\"" }.joined(separator: ", ")
                c.info("Add this to \(existing.path)")
                c.info("(merge it into an existing \"customizations.titan\" block if there is one), then run `titan up`:")
                print("\n  \"customizations\": {\n    \"titan\": { \"services\": [\(list)] }\n  }\n")
                return
            }
            let url = project.root.appendingPathComponent(".devcontainer/devcontainer.json")
            let text = EnvironmentResolver.generateDevcontainer(for: project, services: services)
            if global.dryRun { print(text, terminator: ""); return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            c.success("Wrote \(url.path) with services: \(services.joined(separator: ", "))")
            c.info("  Next: titan up")
        }
    }
}

struct Up: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create or start this project's VM.")
    @OptionGroup var global: GlobalOptions
    @Flag(help: "Recreate the VM from scratch.") var rebuild = false

    func run() throws {
        let engine = global.engine()
        let env = try guarded(engine.console) { try engine.up(rebuild: rebuild) }
        let c = engine.console
        ensureShellHook(c, dryRun: global.dryRun)
        startAlwaysOnTunnels(engine: engine, env: env, console: c)
        c.success("\(engine.project.name) is running in \(engine.project.containerName)")
        c.info("  config   \(env.origin)")
        c.info("  image    \(env.image.display)")
        c.info("  mounted  \(engine.project.root.path) → \(env.workspaceFolder)")
        let ports = engine.publishedPorts(env)
        if !ports.isEmpty {
            c.info("  ports    " + ports.map { p in
                "http://localhost:\(p.host)" + (p.host == p.guest ? "" : c.paint(" (→ \(p.guest) in VM)", "2"))
            }.joined(separator: "  "))
        }
        for svc in engine.serviceReports(env) {
            let host = svc.ports.first.map { "  localhost:\($0.host)" } ?? ""
            let vars = svc.appEnv.keys.sorted().joined(separator: ", ")
            c.info("  service  \(svc.name) (\(svc.image))\(host)" + (vars.isEmpty ? "" : c.paint("  → \(vars)", "2")))
        }
        if !env.shims.isEmpty {
            c.info("  shims    \(env.shims.joined(separator: " "))" +
                   (ProcessInfo.processInfo.environment["TITAN_HOOK"] == nil
                    ? c.paint("   (enable with: eval \"$(titan hook zsh)\")", "2") : ""))
        }
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command inside the project's VM (starting it if needed).",
        discussion: """
        Arguments after `--` go to the command unchanged. The VM starts (or is set up) if needed; paths inside the project are mapped into the VM, and the exit code is passed back.

        Example:
          titan run -- npm test
        """)

    @OptionGroup var global: GlobalOptions
    @Flag(help: .hidden) var shim = false
    @Flag(help: "Run as root (for projects that use their own user).") var root = false
    @Argument(parsing: .captureForPassthrough, help: "Command and arguments.") var command: [String] = []

    func run() throws {
        // `command` captures everything (so flags reach the VM command); only a leading
        // -h/--help before any `--` is for titan itself.
        if let first = command.first, ["-h", "--help", "help"].contains(first) {
            print(Titan.helpMessage(for: Run.self))
            return
        }
        let args = command.first == "--" ? Array(command.dropFirst()) : command
        let engine = global.engine(quiet: shim && !global.verbose)
        // Shims stay silent day to day, but a first-run setup must show its progress.
        let announce: Console? = shim ? global.console() : nil
        try guarded(engine.console) {
            try engine.run(args, cwd: FileManager.default.currentDirectoryPath, announce: announce, asRoot: root)
        }
    }
}

struct Shell: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open an interactive shell inside the project's VM.",
        discussion: "You get a Linux prompt in your project folder; type `exit` to come back to the Mac (the VM keeps running). Commands run as root unless the project sets `customizations.titan.user` (e.g. \"me\" for your own user with sudo); then --root opens a root shell.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Project or VM to enter, from any folder: a project name (shop), VM name, service (shop/postgres) or path. Default: the current folder's project.")
    var target: String?
    @Flag(help: "Open a root shell (for projects that use their own user).") var root = false
    @Flag(help: "Outside a Titan project (or if the VM can't start), open your normal Mac shell instead. Used by `titan vscode --global`.")
    var orMac = false

    func run() throws {
        if orMac, target == nil {
            let project = Project.discover(from: URL(fileURLWithPath: global.cwd))
            guard project.isOptedIn else { Shell.execMacShell() }
            do {
                let code = try global.engine().shell(cwd: FileManager.default.currentDirectoryPath, asRoot: root)
                throw ExitCode(code)
            } catch let error as TitanError {
                global.console().error(error.description)
                global.console().info("Opening a Mac shell instead.")
                Shell.execMacShell()
            }
        }
        var engine = global.engine()
        let code = try guarded(engine.console) { () -> Int32 in
            var cwd = FileManager.default.currentDirectoryPath
            if let target {
                switch try ProjectLookup.find(target, in: Registry.load(.standard).liveProjects) {
                case .project(let project):
                    engine = global.engine(project: project)
                    // Land in the project folder unless we're already inside it.
                    if project.guestPath(forHost: cwd, workspaceFolder: "/w") == nil { cwd = project.root.path }
                case .service(let project, let service):
                    try global.engine(project: project).serviceShell(service)
                }
            }
            return try engine.shell(cwd: cwd, asRoot: root)
        }
        if code != 0 { throw ExitCode(code) }
    }
}

extension Shell {
    /// Replaces titan with the user's login shell (as VS Code itself would start it).
    static func execMacShell() -> Never {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let argv0 = "-" + URL(fileURLWithPath: shell).lastPathComponent   // leading "-" = login shell
        let args = [strdup(argv0), nil]
        execv(shell, args)
        perror("titan: exec \(shell)")
        Darwin.exit(127)
    }
}

struct Down: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the project's VM and its services (--rm deletes them; data is kept).")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("rm"), help: "Delete the VMs instead of just stopping them (service data is kept).") var remove = false
    @Flag(help: "Also delete service data (databases). Implies --rm.") var volumes = false

    func run() throws {
        let engine = global.engine()
        try guarded(engine.console) {
            // A link to a stopped VM is useless: close the project's tunnels first.
            if !TunnelStore().list().filter({ $0.spec.projectRoot == engine.project.root.path }).isEmpty {
                Share.stopTunnels(project: engine.project, ports: [], store: TunnelStore(), console: engine.console)
            }
            stopFileRelay(engine.project)
            try engine.down(remove: remove || volumes, volumes: volumes)
        }
    }
}

struct Rebuild: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Recreate the VM from the current config.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        let engine = global.engine()
        try guarded(engine.console) { try engine.up(rebuild: true) }
        engine.console.success("Rebuilt \(engine.project.containerName)")
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show this project's environment and VM state.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        let engine = global.engine()
        let r = engine.status()
        let c = engine.console
        let state: String = switch r.status {
        case .running: c.paint("running", "32")
        case .stopped: c.paint("stopped", "33")
        case .missing: c.paint("not created", "2")
        }
        print("project   \(r.project.root.path)")
        print("vm        \(r.containerName)  \(state)")
        if let env = r.environment {
            print("config    \(env.origin)")
            print("image     \(env.image.display)")
            print("workspace \(env.workspaceFolder)")
            if let wanted = VMUser.resolve(env.user) {
                let active = engine.activeUser(env)
                print("user      \(wanted.name)" + (active == nil && r.status != .missing
                    ? c.paint("  (this VM predates user support and runs as root; `titan rebuild` switches)", "2") : ""))
            } else {
                print("user      root")
            }
            let ports = r.status == .missing ? env.ports.map(PortMapping.same) : engine.publishedPorts(env)
            if !ports.isEmpty { print("ports     \(ports.map(\.description).joined(separator: ", "))") }
            if r.status != .missing, engine.forwarderDirectory != nil, ports.contains(where: { $0.via == nil }) {
                print("          " + c.paint("created before the port forwarder: apps on 127.0.0.1 aren't reachable; `titan rebuild` fixes it", "2"))
            }
            if !env.shims.isEmpty { print("shims     \(env.shims.joined(separator: " "))") }
            for svc in engine.serviceReports(env) {
                let st: String = switch svc.status {
                case .running: c.paint("running", "32")
                case .stopped: c.paint("stopped", "33")
                case .missing: c.paint("not created", "2")
                }
                let host = svc.ports.first.map { "  localhost:\($0.host)" } ?? ""
                print("service   \(svc.name)  \(st)  \(svc.image)\(host)")
            }
        } else if let err = r.environmentError {
            print("config    \(c.paint("error: " + err, "31"))")
        }
        if let res = r.resources {
            print("resources \(res.cpus) CPUs, \(Resources.formatBytes(res.memoryBytes)) memory")
            if let planned = r.plannedMemory.flatMap(Resources.parseBytes), planned != res.memoryBytes {
                print("          " + c.paint("new VMs get \(Resources.formatBytes(planned)); `titan rebuild` applies it", "2"))
            }
        } else if let planned = r.plannedMemory {
            print("resources \(planned) memory when created")
        }
        if let lock = r.lock { print("lock      \(lock.pinnedReference)") }
        for t in TunnelStore().list() where t.spec.projectRoot == r.project.root.path {
            print("tunnel    \(t.url ?? "starting…") → \(t.spec.guestPort)" + (t.spec.password != nil ? c.paint("  (password)", "2") : ""))
        }
        if r.drifted { c.warn("Config changed since the VM was created. Run `titan rebuild`.") }
    }
}

struct Ps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List every Titan VM on this Mac: project, folder, status, memory, ports.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .shortAndLong, help: "Also list known projects that have no VM right now.") var all = false
    @Flag(help: "Machine-readable output.") var json = false

    func run() throws {
        let c = global.console()
        try guarded(c) {
            let o = try Overview.build(runtime: AppleContainerRuntime(runner: ProcessRunner()), includeIdle: all)
            if json { print(jsonText(o)); return }
            guard !o.rows.isEmpty else {
                print("No Titan VMs on this Mac. Run `titan up` in a project (or just use it, with the shell hook).")
                return
            }
            print(table(o, console: c))
            let tunnels = TunnelStore().list()
            if !tunnels.isEmpty {
                print("\nTUNNELS")
                Share.printList(tunnels, console: c)
            }
            var summary = "\n\(o.running) running · \(o.stopped) stopped"
            if o.memoryInUse > 0 { summary += " · \(Resources.formatBytes(o.memoryInUse)) memory in use" }
            print(summary)
            if o.rows.contains(where: { $0.kind == .unknown }) {
                print(c.paint("? = a titan VM whose project folder is gone; delete it with `container delete <vm>`", "2"))
            }
        }
    }

    func table(_ o: Overview, console c: Console) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func folder(_ p: String?) -> String {
            guard let p else { return "-" }
            return Ps.shorten(p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p)
        }
        var cells: [[String]] = [["PROJECT", "FOLDER", "STATUS", "MEMORY", "PORTS"]]
        var statuses: [ContainerStatus?] = [nil]
        for r in o.rows {
            let name: String = switch r.kind {
            case .app: r.project
            case .service(let s): "  └ \(s)"
            case .unknown: "? \(r.vm)"
            }
            let status = r.status == .missing ? "no VM" : r.status.rawValue
            var memory = "-"
            if let used = r.memoryUsedBytes { memory = "\(Resources.formatBytes(used)) / \(Resources.formatBytes(r.memoryLimitBytes))" }
            let ports = r.ports.map { "localhost:\($0.host)" + ($0.host == $0.guest ? "" : "→\($0.guest)") }.joined(separator: " ")
            cells.append([name, r.kind == .app || r.kind == .unknown ? folder(r.folder) : "", status, memory, ports.isEmpty ? "-" : ports])
            statuses.append(r.status)
        }
        let widths = (0..<5).map { col in cells.map { $0[col].count }.max() ?? 0 }
        return zip(cells, statuses).map { row, status in
            row.enumerated().map { i, cell in
                let padded = i == 4 ? cell : cell.padding(toLength: widths[i] + 2, withPad: " ", startingAt: 0)
                guard let status else { return c.paint(padded, "1") }  // header row
                guard i == 2 else { return padded }
                return switch status {
                case .running: c.paint(padded, "32")
                case .stopped: c.paint(padded, "33")
                case .missing: c.paint(padded, "2")
                }
            }.joined()
        }.joined(separator: "\n")
    }

    /// Keeps both ends of a long path: "/private/tmp/…/scratchpad/ps-demo".
    static func shorten(_ path: String, max: Int = 40) -> String {
        guard path.count > max else { return path }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var head = parts.prefix(3).joined(separator: "/"), tail = parts.last ?? ""
        for part in parts.dropFirst(3).dropLast().reversed() {
            if head.count + tail.count + part.count + 3 > max { break }
            tail = part + "/" + tail
        }
        if head.count + tail.count + 3 > max { head = String(head.prefix(Swift.max(1, max - tail.count - 3))) }
        return head + "/…/" + tail
    }

    func jsonText(_ o: Overview) -> String {
        let rows: [[String: Any]] = o.rows.map { r in
            var d: [String: Any] = ["project": r.project, "vm": r.vm, "status": r.status.rawValue, "image": r.image,
                                    "memoryLimitBytes": r.memoryLimitBytes,
                                    "ports": r.ports.map { ["localhost": $0.host, "app": $0.guest] }]
            switch r.kind {
            case .app: d["kind"] = "app"
            case .service(let s): d["kind"] = "service"; d["service"] = s
            case .unknown: d["kind"] = "unknown"
            }
            if let f = r.folder { d["folder"] = f }
            if let m = r.memoryUsedBytes { d["memoryUsedBytes"] = m }
            return d
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["running": o.running, "stopped": o.stopped, "vms": rows],
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a service's logs (e.g. Postgres), or the VM's boot log.",
        discussion: """
        Your app's own output goes to the terminal where you started it (e.g. `npm run dev`); visits to a shared link are in `titan share --log`.

        Examples:
          titan logs postgres          everything so far
          titan logs postgres -f       follow live (Ctrl-C to stop)
          titan logs redis -n 50       the last 50 lines
          titan logs --boot            the project VM's boot log (when it won't start)
        """)
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Service name (default: the project's only service).") var service: String?
    @Flag(name: .shortAndLong, help: "Keep following new lines.") var follow = false
    @Option(name: .short, help: "Show only the last N lines.") var n: Int?
    @Flag(help: "Show the boot log instead of the output.") var boot = false

    func run() throws {
        let engine = global.engine()
        let c = engine.console
        let code = try guarded(c) { () -> Int32 in
            let env = try engine.resolve()
            let target = try engine.logsTarget(service: service, boot: boot, env: env)
            if case .choose(let services) = target {
                if services.isEmpty {
                    print("\(engine.project.name) has no services, so there are no service logs.")
                    print(c.paint("Your app's output is in the terminal where you started it; shared-link visits: titan share --log; VM boot log: titan logs --boot", "2"))
                } else {
                    print("Which service? " + services.map { "titan logs \($0)" }.joined(separator: "  ·  "))
                }
                return 0
            }
            return try engine.showLogs(target, follow: follow, lines: n, boot: boot)
        }
        if code != 0 && code != 130 { throw ExitCode(code) }
    }
}

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show CPU, memory, disk and network use of this project's VM.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "Seconds between the two CPU samples.") var interval: Double = 1
    @Flag(help: "Keep refreshing until Ctrl-C.") var watch = false

    func run() throws {
        let engine = global.engine()
        try guarded(engine.console) {
            repeat {
                let r = try engine.stats(interval: interval)
                if watch { print("\u{1B}[H\u{1B}[2J", terminator: "") }
                print(render(r, console: engine.console))
            } while watch
        }
    }

    func render(_ r: Engine.StatsReport, console c: Console) -> String {
        let f = Resources.formatBytes
        let s = r.sample
        var lines = ["vm         \(r.containerName)  \(c.paint("running", "32"))"]
        let cores = r.resources.map { " of \($0.cpus * 100)% (\($0.cpus) CPUs)" } ?? ""
        lines.append(String(format: "cpu        %.1f%%", r.cpuPercent) + cores)
        let limit = s.memoryLimitBytes > 0 ? s.memoryLimitBytes : (r.resources?.memoryBytes ?? 0)
        var mem = "memory     \(f(s.memoryUsageBytes))"
        if limit > 0 {
            let pct = Double(s.memoryUsageBytes) / Double(limit) * 100
            mem += " / \(f(limit))  " + String(format: "(%.0f%%)", pct)
            if pct >= 85 { mem += "  " + c.paint("near limit: raise customizations.titan.memory", "33") }
        }
        lines.append(mem)
        lines.append("processes  \(s.processes)")
        lines.append("disk io    read \(f(s.blockReadBytes)), written \(f(s.blockWriteBytes))")
        lines.append("network    rx \(f(s.networkRxBytes)), tx \(f(s.networkTxBytes))")
        if let size = r.imageSizeBytes { lines.append("image      \(f(size)) download (unpacked on disk it is ~3× larger)") }
        if let st = r.imageStore {
            lines.append("all images \(st.count) images, \(f(st.sizeBytes)) (\(f(st.reclaimableBytes)) reclaimable)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Asks on a TTY; refuses without one unless `--yes` was given.
func confirm(_ question: String, yes: Bool, console: Console) -> Bool {
    if yes { return true }
    guard isatty(0) == 1 else {
        console.warn("Not a terminal: pass --yes to confirm.")
        return false
    }
    print("\(question) [y/N] ", terminator: "")
    return ["y", "yes"].contains(readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? "")
}

struct Share: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Share the project's app on a public HTTPS address (Cloudflare tunnel).",
        discussion: """
        By default you get a random *.trycloudflare.com link that lasts while the command runs. With your own domain on Cloudflare, --domain gives a stable address that never changes; Titan remembers it for the project. Needs cloudflared (brew install cloudflared).

        Examples:
          titan share                        quick link, until Ctrl-C
          titan share -b --ttl 2h            in the background; closes after 2 hours
          titan share --protect              visitors need a password
          titan share 5173 8000              one link per port
          titan share --domain dev.example.com --always
          titan share --list | --stop | --log
        """)
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Ports to share, as the app sees them (default: the first forwarded port).") var ports: [Int] = []
    @Flag(name: [.short, .long], help: "Keep running after this terminal closes.") var background = false
    @Option(help: "Close the tunnel after this long (e.g. 30m, 2h, 1d).") var ttl: String?
    @Flag(help: "Ask visitors for a password (Titan makes one up).") var protect = false
    @Option(help: "Ask visitors for this password.") var password: String?
    @Option(help: "Your hostname on a Cloudflare domain, for a stable address (remembered for this project).") var domain: String?
    @Flag(help: "With a domain: bring the tunnel up whenever this project's VM starts.") var always = false
    @Flag(help: "Forget the remembered domain for these ports.") var forget = false
    @Flag(help: "List the tunnels running on this Mac.") var list = false
    @Flag(help: "Stop this project's tunnels (or only the given ports).") var stop = false
    @Flag(help: "Follow the visit log: who is using the link.") var log = false
    @Flag(help: "Copy the link to the clipboard.") var copy = false
    @Flag(help: "Pass the public hostname through instead of rewriting Host to localhost.") var keepHost = false
    @Option(help: .hidden) var supervise: String?

    func run() throws {
        let c = global.console()
        let store = TunnelStore()
        if let supervise { return try Share.superviseDetached(specPath: supervise, store: store) }
        try guarded(c) {
            if list { return Share.printList(store.list(), console: c) }
            let engine = global.engine()
            let project = engine.project
            if stop { return Share.stopTunnels(project: project, ports: ports, store: store, console: c) }
            if log { return try followLog(project: project, store: store, console: c) }
            if forget {
                var choices = DomainChoices.load(.standard)
                let env = try engine.resolve()
                for p in (ports.isEmpty ? Array(env.ports.prefix(1)) : ports) { choices.set(project, port: p, nil) }
                try choices.save(.standard)
                c.success("Forgot the domain for \(project.name). `titan share` uses quick links again.")
                return
            }
            try share(engine: engine, store: store, console: c)
        }
    }

    // MARK: Sharing

    func share(engine: Engine, store: TunnelStore, console c: Console) throws {
        guard let cloudflared = ProcessRunner().which(Tunnel.binary) else {
            throw TitanError.message("`cloudflared` not found. Install it with: \(Tunnel.installHint)")
        }
        if let domain, ports.count > 1 { throw TitanError.message("--domain \(domain) is for one port; share other ports separately.") }
        if let domain, !TunnelPlan.isValidDomain(domain.lowercased()) {
            throw TitanError.message("'\(domain)' isn't a valid hostname. Use something like dev.example.com.")
        }
        if always && domain == nil && ports.allSatisfy({ DomainChoices.load(.standard).choice(engine.project, port: $0) == nil }) {
            throw TitanError.message("--always needs a stable address: add --domain <your hostname>.")
        }
        let ttlSeconds = try ttl.map { t -> Int in
            guard let s = TunnelPlan.parseDuration(t) else { throw TitanError.message("--ttl takes a duration like 30m, 2h or 1d.") }
            return s
        }
        let env = global.dryRun ? try engine.resolve() : try engine.ensureUp()
        let published = engine.publishedPorts(env)
        // Any port the app uses works, forwarded or not; a Mac-side number of a remapped
        // forward (5174 for 5173) is accepted too.
        let guests: [Int]
        if ports.isEmpty {
            guard let first = published.first?.guest ?? env.ports.first else {
                throw TitanError.message("Which port? This project forwards none; say it, e.g. `titan share 5173`.")
            }
            guests = [first]
        } else {
            guests = ports.map { p in published.first(where: { $0.host == p && $0.guest != p })?.guest ?? p }
        }

        var choices = DomainChoices.load(.standard)
        var specs: [TunnelSpec] = []
        for guest in guests {
            let remembered = choices.choice(engine.project, port: guest)
            let host = (domain ?? remembered?.domain)?.lowercased()
            let pw = password ?? (protect ? (remembered?.password ?? TunnelPlan.generatePassword()) : remembered?.password)
            var spec = TunnelSpec(projectRoot: engine.project.root.path, projectName: engine.project.name,
                                  containerName: engine.project.containerName, guestPort: guest, hostPort: guest,
                                  domain: host, password: pw, ttlSeconds: ttlSeconds, keepHost: keepHost)
            if let running = store.record(spec.id) {   // already shared: hand back that link
                Share.printLink(running, console: c, note: "already shared")
                continue
            }
            if !global.dryRun {
                let target = try engine.shareTarget(guestPort: guest, env: env)
                spec.upstreamHost = target.host
                spec.hostPort = target.port
            }
            specs.append(spec)
            if let host, domain != nil || always {
                choices.set(engine.project, port: guest,
                            .init(domain: host, always: always || (remembered?.always ?? false), password: pw))
            }
        }
        if specs.isEmpty { return }
        if global.dryRun {
            for s in specs { print("would share \(s.projectName):\(s.guestPort) via " + (s.domain.map { "https://\($0)" } ?? "a quick tunnel")) }
            return
        }
        // A domain needs a named tunnel and a DNS record in the user's Cloudflare account.
        for s in specs where s.domain != nil {
            let setup = NamedTunnelSetup(runner: ProcessRunner(), cloudflared: cloudflared)
            guard setup.isLoggedIn else {
                throw TitanError.message("To use your domain, sign cloudflared in to Cloudflare once:\n"
                                         + "    cloudflared tunnel login\n  (pick your domain in the browser), then run this again.")
            }
            let name = try setup.ensureTunnel(for: s.domain!, console: c)
            try setup.routeDNS(s.domain!, to: name, console: c)
        }
        try choices.save(.standard)

        for s in specs where !engine.isListening(guestPort: s.guestPort, env: env) {
            c.warn("Nothing is listening on port \(s.guestPort) in the VM yet; visitors see a \"start the app\" page until it is.")
        }
        let gate = TunnelPlan.gateBinary(executable: titanExecutablePath)
        if background {
            for s in specs {
                let record = try Share.startBackground(s, store: store)
                Share.printLink(record, console: c)
                if copy, let url = record.url { copyToClipboard(url, console: c) }
            }
            c.info("  Stop with `titan share --stop`; see who's visiting with `titan share --log`.")
            return
        }
        try runForeground(specs, store: store, cloudflared: cloudflared, gate: gate, console: c)
    }

    func runForeground(_ specs: [TunnelSpec], store: TunnelStore, cloudflared: String, gate: String?, console c: Console) throws {
        let supervisors = specs.map { s in
            TunnelSupervisor(spec: s, store: store, cloudflared: cloudflared, gatePath: gate,
                             say: { msg in FileHandle.standardError.write(Data(("! " + msg + "\n").utf8)) })
        }
        // Ctrl-C reaches cloudflared too (same process group); stop cleanly instead of "reconnecting".
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { supervisors.forEach { $0.stop() } }
            source.resume()
            sources.append(source)
        }
        defer { sources.forEach { $0.cancel() } }
        for (i, sup) in supervisors.enumerated() {
            c.step("Opening a tunnel to \(specs[i].projectName):\(specs[i].guestPort)…")
            let url = try sup.start()
            sup.onURL = { new in c.warn("The tunnel reconnected with a new link: \(new)") }
            Share.printLink(TunnelRecord(spec: specs[i], pid: getpid(), url: url, startedAt: Date(),
                                         expiresAt: sup.expiresAt, visitLog: ""), console: c)
            if copy && i == 0 { copyToClipboard(url, console: c) }
        }
        c.info("  Press Ctrl-C to close" + (specs.count > 1 ? " them." : " it."))
        let group = DispatchGroup()
        for sup in supervisors {
            group.enter()
            Thread.detachNewThread { sup.runUntilStopped(); group.leave() }
        }
        group.wait()
        c.success("Tunnel closed.")
    }

    func copyToClipboard(_ url: String, console c: Console) {
        if let pb = Process.launched("/usr/bin/pbcopy", input: url) { pb.waitUntilExit(); c.info("  (copied to clipboard)") }
    }

    // MARK: Background tunnels

    /// Starts a detached supervisor (`titan share --supervise <spec>`) and waits for its link.
    static func startBackground(_ spec: TunnelSpec, store: TunnelStore, timeout: TimeInterval = 75) throws -> TunnelRecord {
        let specURL = try store.saveSpec(spec)
        let log = store.supervisorLog(spec.id).path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup + & detaches it from this terminal; it survives the terminal closing.
        p.arguments = ["-c", #"nohup "$0" share --supervise "$1" >>"$2" 2>&1 &"#, titanExecutablePath, specURL.path, log]
        try p.run()
        p.waitUntilExit()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = store.record(spec.id), r.url != nil { return r }
            Thread.sleep(forTimeInterval: 0.3)
        }
        let tail = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").suffix(3).joined(separator: "\n  ")
        throw TitanError.message("The background tunnel didn't come up.\n  \(tail)")
    }

    /// The detached supervisor's main loop.
    static func superviseDetached(specPath: String, store: TunnelStore) throws {
        let spec = try store.loadSpec(URL(fileURLWithPath: specPath))
        guard let cloudflared = ProcessRunner().which(Tunnel.binary) ?? ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TitanError.message("cloudflared not found")
        }
        let sup = TunnelSupervisor(spec: spec, store: store, cloudflared: cloudflared,
                                   gatePath: TunnelPlan.gateBinary(executable: titanExecutablePath),
                                   say: { print("[\(Date())] \($0)") })
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { sup.stop() }
            source.resume()
            sources.append(source)
        }
        let url = try sup.start()
        print("[\(Date())] \(spec.projectName):\(spec.guestPort) → \(url)")
        sup.runUntilStopped()
        try? FileManager.default.removeItem(atPath: specPath)
        sources.forEach { $0.cancel() }
    }

    static func stopTunnels(project: Project, ports: [Int], store: TunnelStore, console c: Console) {
        let mine = store.list().filter { $0.spec.projectRoot == project.root.path && (ports.isEmpty || ports.contains($0.spec.guestPort)) }
        guard !mine.isEmpty else { c.info("No tunnels running for \(project.name)."); return }
        for r in mine { kill(r.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !store.list().filter({ r in mine.contains { $0.spec.id == r.spec.id } }).isEmpty {
            Thread.sleep(forTimeInterval: 0.2)
        }
        for r in mine { c.success("Closed \(r.url ?? "the tunnel") (\(project.name):\(r.spec.guestPort))") }
    }

    func followLog(project: Project, store: TunnelStore, console c: Console) throws {
        let env = try global.engine().resolve()
        let port = ports.first ?? env.ports.first ?? 0
        let path = store.visitLog("\(project.containerName)-\(port)").path
        guard FileManager.default.fileExists(atPath: path) else {
            c.info("No visits logged yet for \(project.name):\(port). Share it first with `titan share`.")
            return
        }
        c.info("Visits to \(project.name):\(port) (Ctrl-C to stop):")
        _ = try ProcessRunner().passthrough(["tail", "-n", "20", "-f", path])
    }

    // MARK: Output

    static func printLink(_ r: TunnelRecord, console c: Console, note: String? = nil) {
        guard let url = r.url else { return }
        var line = "\n  " + c.paint(url, "1;32") + c.paint("  → \(r.spec.projectName):\(r.spec.guestPort)", "2")
        if let note { line += c.paint("  (\(note))", "2") }
        print(line)
        if let pw = r.spec.password { print("  password: " + c.paint(pw, "1") + c.paint("  (any user name)", "2")) }
        if let exp = r.expiresAt { print(c.paint("  closes at \(DateFormatter.localizedString(from: exp, dateStyle: .none, timeStyle: .short))", "2")) }
        if r.spec.domain == nil { print(c.paint("  (a brand-new link can take ~10s to resolve)", "2")) }
        print("")
        if r.spec.password == nil { c.info("  Anyone with this link can reach your app.") }
    }

    static func printList(_ records: [TunnelRecord], console c: Console) {
        guard !records.isEmpty else { print("No tunnels running. Start one with `titan share`."); return }
        for r in records {
            var extras: [String] = []
            if r.spec.password != nil { extras.append("password") }
            if let exp = r.expiresAt { extras.append("closes \(DateFormatter.localizedString(from: exp, dateStyle: .none, timeStyle: .short))") }
            print("\(r.spec.projectName):\(r.spec.guestPort)".padding(toLength: 22, withPad: " ", startingAt: 0)
                  + (r.url ?? "starting…") + (extras.isEmpty ? "" : c.paint("  (\(extras.joined(separator: ", ")))", "2")))
        }
    }
}

/// Starts the `--always` tunnels remembered for this project (after `titan up`).
func startAlwaysOnTunnels(engine: Engine, env: ResolvedEnvironment, console c: Console) {
    let choices = DomainChoices.load(.standard).projects[engine.project.root.path] ?? [:]
    let store = TunnelStore()
    for (portText, choice) in choices.sorted(by: { $0.key < $1.key }) where choice.always {
        guard let port = Int(portText) else { continue }
        var spec = TunnelSpec(projectRoot: engine.project.root.path, projectName: engine.project.name,
                              containerName: engine.project.containerName, guestPort: port, hostPort: port,
                              domain: choice.domain, password: choice.password)
        if store.record(spec.id) != nil { continue }
        do {
            let target = try engine.shareTarget(guestPort: port, env: env)
            spec.upstreamHost = target.host
            spec.hostPort = target.port
            let r = try Share.startBackground(spec, store: store)
            c.info("  tunnel   \(r.url ?? "https://\(choice.domain)") → \(port)")
        } catch {
            c.warn("Couldn't bring up https://\(choice.domain): \(error)")
        }
    }
}

extension Process {
    static func launched(_ path: String, input: String) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        let pipe = Pipe()
        p.standardInput = pipe
        guard (try? p.run()) != nil else { return nil }
        pipe.fileHandleForWriting.write(Data(input.utf8))
        try? pipe.fileHandleForWriting.close()
        return p
    }
}

struct GC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Delete images that no Titan project or VM needs any more.",
        discussion: """
        Keeps images used by any VM and images pinned or used by projects you've run `titan up` in. By default only images Titan pulled or built are removed; --all also removes other unused images. Unused shared toolchains are removed too. Asks before deleting.
        """)
    @OptionGroup var global: GlobalOptions
    @Flag(help: "Also remove unused images Titan didn't create.") var all = false
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false

    func run() throws {
        let c = global.console()
        // Reads always hit the real runtime; --dry-run only skips the delete.
        let runtime = AppleContainerRuntime(runner: ProcessRunner())
        let gc = GarbageCollector(runtime: runtime)
        try guarded(c) {
            let plan = try gc.plan()
            let f = Resources.formatBytes
            for k in plan.kept { print(c.paint("keep    ", "2") + "\(k.image.displayName)  " + c.paint("(\(k.reason))", "2")) }
            let remove = plan.titanImages + (all ? plan.otherImages : [])
            for i in remove { print(c.paint("remove  ", "31") + "\(i.displayName)  \(f(i.sizeBytes))") }
            if !all, !plan.otherImages.isEmpty {
                let names = plan.otherImages.map(\.displayName).joined(separator: ", ")
                print(c.paint("skip    \(names)  (not created by Titan; use --all)", "2"))
            }
            let known = Registry.load(TitanPaths.standard).liveProjects.count
            print(c.paint("(Titan knows \(known) project(s): the ones you've run `titan up` in. Images other projects pin are re-pulled on their next `up`.)", "2"))
            for v in plan.toolchainVolumes { print(c.paint("remove  ", "31") + "\(v)  " + c.paint("(toolchain no project uses)", "2")) }
            guard !remove.isEmpty || !plan.toolchainVolumes.isEmpty else { c.success("Nothing to remove."); return }
            let download = remove.reduce(0) { $0 + $1.sizeBytes }
            if !remove.isEmpty { print("\n\(remove.count) image(s), \(f(download)) download size (plus their unpacked copies on disk).") }
            if !plan.toolchainVolumes.isEmpty { print("\(plan.toolchainVolumes.count) toolchain volume(s).") }
            if global.dryRun { print(c.paint("--dry-run: nothing deleted.", "2")); return }
            guard confirm("Delete them?", yes: yes, console: c) else { return }
            try gc.removeToolchainVolumes(plan.toolchainVolumes)
            guard !remove.isEmpty else { c.success("Removed \(plan.toolchainVolumes.count) toolchain volume(s)."); return }
            let before = runtime.imageStoreUsage()?.sizeBytes
            try gc.remove(remove)
            let after = runtime.imageStoreUsage()?.sizeBytes
            if let before, let after, before > after {
                c.success("Removed \(remove.count) image(s), freed \(f(before - after)).")
            } else {
                c.success("Removed \(remove.count) image(s).")
            }
        }
    }
}

struct Cache: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or clear the package cache shared by all VMs (npm, pip, Go modules).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "`clean` to delete the shared cache.") var action: String?
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false

    func run() throws {
        let c = global.console()
        let paths = TitanPaths.standard
        let usage = SharedCache.usage(paths)
        let total = usage.reduce(0) { $0 + $1.bytes }
        switch action {
        case nil:
            print("location    \(paths.sharedCache.path)  (mounted in VMs at \(SharedCache.guestPath))")
            for u in usage { print(u.name.padding(toLength: 12, withPad: " ", startingAt: 0) + Resources.formatBytes(u.bytes)) }
            print("total       \(Resources.formatBytes(total))")
        case "clean":
            guard total > 0 else { c.success("Shared cache is already empty."); return }
            if global.dryRun { print("--dry-run: would delete \(Resources.formatBytes(total))."); return }
            guard confirm("Delete \(Resources.formatBytes(total)) of cached packages?", yes: yes, console: c) else { return }
            try SharedCache.clean(paths)
            c.success("Freed \(Resources.formatBytes(total)). VMs re-download packages on next install.")
        default:
            throw ValidationError("Unknown action '\(action!)'. Use `titan cache` or `titan cache clean`.")
        }
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Get this Mac ready: Apple container, its service, the shell hook, and a test VM.",
        discussion: "Safe to run again: it only fixes what's missing, and asks before changing anything.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .shortAndLong, help: "Accept every fix without asking.") var yes = false
    @Option(help: "Shell to set up (default: from $SHELL).") var shell: String?
    @Flag(help: "Skip the test VM.") var skipTest = false

    func run() throws {
        let c = global.console()
        let interactive = isatty(0) == 1
        var problems = 0
        func ok(_ text: String) { print(c.paint("✓", "32") + " " + text) }
        func bad(_ text: String, _ hint: String? = nil) {
            print(c.paint("✗", "31") + " " + text)
            if let hint { print("    " + c.paint(hint, "2")) }
            problems += 1
        }
        /// Asks before a change; without a terminal (and no --yes) only reports.
        func allow(_ question: String) -> Bool {
            if global.dryRun { print(c.paint("    would: \(question)", "2")); return false }
            if yes { return true }
            guard interactive else { return false }
            print("    \(question) [Y/n] ", terminator: "")
            return !["n", "no"].contains(readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? "")
        }

        print(c.paint("Checking this Mac", "1"))
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard machine == "arm64", os.majorVersion >= 26 else {
            bad("Apple container needs Apple silicon and macOS 26+ (this Mac: \(machine), macOS \(os.majorVersion).\(os.minorVersion))")
            throw ExitCode.failure
        }
        ok("Apple silicon, macOS \(os.majorVersion).\(os.minorVersion)")

        // 1. Apple container CLI.
        let runner = ProcessRunner()
        var runtime = AppleContainerRuntime(runner: runner)
        if !runtime.isInstalled() {
            if runner.which("brew") != nil, allow("Apple container isn't installed. Install it with Homebrew (`brew install container`)?") {
                c.step("brew install container")
                _ = try? runner.passthrough(["brew", "install", "container"])
                runtime = AppleContainerRuntime(runner: runner)
            }
            guard runtime.isInstalled() else {
                bad("Apple container isn't installed",
                    "brew install container   (or the installer from https://github.com/apple/container/releases)")
                throw ExitCode.failure
            }
        }
        ok(runtime.version() ?? "container CLI")

        // 2. System service (first start also installs the Linux kernel).
        if runtime.isSystemRunning() {
            ok("container service running")
        } else if allow("Start the container service (first time: downloads the Linux kernel, ~30 MB)?") {
            c.step("container system start")
            if (try? runner.passthrough(["container", "system", "start", "--enable-kernel-install"])) == 0, runtime.isSystemRunning() {
                ok("container service running")
            } else {
                bad("container service didn't start", "Try: container system start")
            }
        } else {
            bad("container service not running", "container system start")
        }

        // 3. Port forwarder (makes localhost-only dev servers reachable).
        if let dir = Forwarder.shareDirectory(executable: titanExecutablePath) {
            ok("port forwarder (\(dir.path))")
        } else {
            bad("port forwarder missing: apps on 127.0.0.1 won't be reachable", "Reinstall titan: make install")
        }

        // 4. Shell hook.
        let shellName = shell ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").lastPathComponent
        if ShellHook.script(for: shellName) == nil {
            bad("shell '\(shellName)' isn't supported yet", "Titan's hook supports zsh and bash; use `titan run -- <cmd>` meanwhile.")
        } else {
            let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            let rc = ShellSetup.rcFile(shell: shellName, home: home)
            let text = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
            switch ShellSetup.state(of: text) {
            case .installed:
                ok("shell hook in \(rc.path)")
            case .managedBlock, .missing:
                let isNew = ShellSetup.state(of: text) == .missing
                if !isNew, (try? ShellSetup.install(into: rc, shell: shellName, titan: titanExecutablePath)) == true {
                    ok("shell hook in \(rc.path) (updated titan's path)")
                } else if !isNew {
                    ok("shell hook in \(rc.path)")
                } else {
                    print(c.paint("    Titan will add to \(rc.path):", "2"))
                    for line in ShellSetup.block(shell: shellName, titan: titanExecutablePath).split(separator: "\n") {
                        print(c.paint("      \(line)", "2"))
                    }
                    if allow("Add the shell hook to \(rc.lastPathComponent)?") {
                        try? FileManager.default.removeItem(at: ShellSetup.declinedMarker())
                        try ShellSetup.install(into: rc, shell: shellName, titan: titanExecutablePath)
                        ok("shell hook added to \(rc.path)")
                    } else {
                        let marker = ShellSetup.declinedMarker()
                        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? Data().write(to: marker)   // don't add it behind the scenes later
                        bad("shell hook not installed", "Add to \(rc.path):  eval \"$(titan hook \(shellName))\"")
                    }
                }
                // Smart shims for non-interactive shells (coding agents, scripts).
                if ShellSetup.state(of: (try? String(contentsOf: rc, encoding: .utf8)) ?? "") != .missing, !global.dryRun {
                    let dir = TitanPaths.standard.shims
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    _ = try? GlobalShims.installPath(shell: shellName, home: home, dir: dir.path)
                    ok("commands also run in the VM from coding agents and scripts (\(dir.path))")
                }
            }
        }

        // 5. A real VM, end to end.
        if !skipTest, runtime.isSystemRunning(), !global.dryRun {
            let image = (runtime.listImages() ?? []).first.map(\.displayName) ?? "debian:bookworm"
            c.step("Starting a test VM (\(image))…")
            let start = Date()
            if let r = try? runner.capture(["container", "run", "--rm", image, "uname", "-sm"]), r.ok {
                ok("test VM: \(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            } else {
                bad("test VM failed to run", "Check `container system status`, then try again.")
            }
        }

        print("")
        if problems > 0 {
            c.warn("\(problems) thing(s) still need attention (see above). Run `titan setup` again after fixing them.")
            throw ExitCode.failure
        }
        c.success("This Mac is ready for Titan.")
        let hookActive = ProcessInfo.processInfo.environment["TITAN_HOOK"] != nil
        c.info("  " + (hookActive ? "" : "Open a new terminal, then: ") + "titan new myapp   (or cd into a project and run your usual commands)")
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check that this Mac and project are ready.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        let engine = global.engine()
        let c = engine.console
        var failures = 0
        func check(_ ok: Bool, _ label: String, hint: String? = nil, warnOnly: Bool = false) {
            if ok {
                print(c.paint("✓", "32") + " " + label)
            } else {
                print(c.paint(warnOnly ? "!" : "✗", warnOnly ? "33" : "31") + " " + label)
                if let hint { print("    " + c.paint(hint, "2")) }
                if !warnOnly { failures += 1 }
            }
        }

        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        check(machine == "arm64", "Apple silicon (\(machine))", hint: "Apple container requires an M-series Mac.")

        let os = ProcessInfo.processInfo.operatingSystemVersion
        check(os.majorVersion >= 26, "macOS \(os.majorVersion).\(os.minorVersion)", hint: "macOS 26 or later is required.")

        let installed = engine.runtime.isInstalled()
        check(installed, installed ? (engine.runtime.version() ?? "container CLI") : "container CLI not found",
              hint: "Install from https://github.com/apple/container/releases")
        if installed {
            check(engine.runtime.isSystemRunning(), "container system service running",
                  hint: "titan up will start it, or run: container system start", warnOnly: true)
        }

        let r = engine.status()
        check(r.environment != nil, "project config: " + (r.environment?.origin ?? r.environmentError ?? "?"))
        check(!r.drifted, "VM matches config", hint: "Run `titan rebuild`.", warnOnly: true)
        check(r.lock?.digest != nil, "titan.lock pins an image digest",
              hint: "Created on first `titan up`; commit it so teammates get identical images.", warnOnly: true)
        check(ProcessInfo.processInfo.environment["TITAN_HOOK"] != nil, "shell hook installed",
              hint: "Add to ~/.zshrc:  eval \"$(titan hook zsh)\"", warnOnly: true)

        if failures > 0 { throw ExitCode.failure }
    }
}

struct Lock: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the image pins in titan.lock, or refresh them with --update.",
        discussion: "titan.lock pins the exact image digests for the app, its services and its toolchains, so every machine runs the same bits. `--update` re-resolves every tag to its current digest; run `titan rebuild` afterwards to use the new images.")
    @OptionGroup var global: GlobalOptions
    @Flag(help: "Re-resolve every image tag and pin its current digest.") var update = false

    func run() throws {
        let engine = global.engine()
        let c = engine.console
        try guarded(c) {
            if update {
                guard engine.runtime.isInstalled() else { throw TitanError.runtimeMissing }
                let changes = try engine.refreshLock()
                if changes.isEmpty { c.success("titan.lock is already up to date.") }
                for change in changes { c.success(change) }
                if !changes.isEmpty { c.info("  Run `titan rebuild` to switch the VM to the new images.") }
            }
            guard let lock = Lockfile.load(engine.project) else {
                c.info("No titan.lock yet. It's written on the first `titan up` (or run `titan lock --update`).")
                return
            }
            if lock.digest != nil { print("app        \(lock.pinnedReference)") }
            for (name, pin) in (lock.services ?? [:]).sorted(by: { $0.key < $1.key }) { print("service    \(name): \(pin.pinnedReference)") }
            for (name, pin) in (lock.toolchains ?? [:]).sorted(by: { $0.key < $1.key }) { print("toolchain  \(name): \(pin.pinnedReference)") }
        }
    }
}

/// Called by the shell hook on `cd` into an opted-in project (titan.lock or devcontainer.json):
/// writes the command shims without starting the VM, so the first `npm …` just works.
struct Activate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Set up command routing for this project (used by the shell hook).",
                                                    shouldDisplay: false)
    @OptionGroup var global: GlobalOptions
    @Flag(help: "Print nothing.") var quiet = false

    func run() throws {
        let engine = global.engine(quiet: true)
        let c = global.console()
        do {
            let cmds = try engine.activate()
            guard !quiet, !cmds.isEmpty else { return }
            let ready = ProjectState.load(engine.project)?.configHash != nil
            let note = ready ? "" : c.paint("  first command sets it up (~1 min)", "2")
            c.info(c.paint("titan", "36") + ": \(engine.project.name) → VM " + c.paint("(\(cmds.joined(separator: " ")))", "2") + note)
        } catch let error as TitanError {
            if !quiet { c.warn("titan: \(engine.project.name): \(error.description) (commands run on the Mac)") }
            throw ExitCode.failure
        }
    }
}

struct Hook: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the shell hook. Add `eval \"$(titan hook zsh)\"` to ~/.zshrc.",
        shouldDisplay: false)
    @Argument(help: "zsh or bash") var shell: String = "zsh"

    func run() throws {
        guard let script = ShellHook.script(for: shell, titan: titanExecutablePath) else {
            throw ValidationError("Unsupported shell '\(shell)'. Use zsh or bash.")
        }
        print(script)
    }
}

struct VSCode: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vscode", abstract: "Make VS Code's integrated terminal open inside the VM.",
        discussion: "Without options: for this project. With --global: for every Titan project (VS Code's user settings); other folders keep the normal Mac terminal.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("global"), help: "Every Titan project gets a Linux terminal; other folders keep the Mac one.") var global_ = false
    @Flag(help: "With --global: undo it.") var remove = false
    @Flag(help: "With --global: show .titan in VS Code's explorer and search again.") var showTitanFolder = false
    @Flag(help: "With --global: hide .titan from VS Code's explorer and search (only that).") var hideTitanFolder = false
    @Option(help: "Editor whose user settings to change with --global: code (VS Code) or cursor.") var editor: String = "code"

    func run() throws {
        let console = global.console()
        if global_ {
            let app = editor.lowercased() == "cursor" ? "Cursor" : "Code"
            let url = VSCodeIntegration.userSettingsURL(app: app)
            if showTitanFolder || hideTitanFolder {
                let hide = hideTitanFolder
                if case .manual(let snippet) = try VSCodeIntegration.setTitanFolderHidden(hide, settings: url) {
                    console.warn("\(url.path) has comments; \(hide ? "add" : "remove") this yourself:"); print(snippet)
                } else if hide {
                    console.success(".titan is hidden from the editor's explorer and search. Show it: titan vscode --global --show-titan-folder")
                } else {
                    console.success(".titan is visible in the editor again. Hide it: titan vscode --global --hide-titan-folder")
                }
                return
            }
            if remove {
                _ = try? VSCodeIntegration.setTitanFolderHidden(false, settings: url)
                if try VSCodeIntegration.removeGlobal(settings: url) {
                    console.success("Removed Titan's terminal from \(url.path)")
                } else {
                    console.info("Titan's terminal isn't set in \(url.path).")
                }
                return
            }
            switch try VSCodeIntegration.installGlobal(settings: url, titan: titanExecutablePath) {
            case .written(let written):
                console.success("Updated \(written.path)  (backup: settings.json.titan-backup)")
                console.info("  New terminals open inside the VM in Titan projects, and on the Mac everywhere else.")
                if case .written = try VSCodeIntegration.setTitanFolderHidden(true, settings: written) {
                    console.info("  .titan is hidden from the explorer and search (show it: titan vscode --global --show-titan-folder).")
                }
                console.info("  Undo with: titan vscode --global --remove")
            case .manual(let snippet):
                console.warn("\(url.path) has comments or its own terminal profiles; add this yourself:")
                print(snippet)
            }
            return
        }
        let project = Project.discover(from: URL(fileURLWithPath: global.cwd))
        switch try VSCodeIntegration.install(project: project, titan: titanExecutablePath) {
        case .written(let url):
            console.success("Updated \(url.path)")
            console.info("  New VS Code terminals in this folder now open inside the Titan VM.")
        case .manual(let snippet):
            console.warn(".vscode/settings.json contains comments; add this yourself:")
            print(snippet)
        }
    }
}

/// Keeps hot reload working: starts the project's file-change relay in the background unless
/// it's already running (TITAN_NO_FILE_RELAY=1 turns it off).
func startFileRelay(_ project: Project) {
    guard ProcessInfo.processInfo.environment["TITAN_NO_FILE_RELAY"] == nil,
          FileRelay.runningPid(project) == nil else { return }
    let log = project.stateDir.appendingPathComponent("relay.log").path
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", #"nohup "$0" -C "$1" relay >>"$2" 2>&1 </dev/null &"#, titanExecutablePath, project.root.path, log]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

func stopFileRelay(_ project: Project) {
    if let pid = FileRelay.runningPid(project) { kill(pid, SIGTERM) }
}

/// The background file-change relay (started by `titan up`; see FileRelay).
struct Relay: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Relay Mac file changes into the VM (runs in the background).",
                                                    shouldDisplay: false)
    @OptionGroup var global: GlobalOptions

    func run() throws {
        let engine = global.engine(quiet: true)
        let env = try engine.resolve()
        let name = engine.project.containerName
        let runtime = engine.runtime
        for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, { _ in Darwin.exit(0) }) }
        let say: (String) -> Void = { print("[\(Date())] \($0)") }
        // Idle check once a minute (see IdleStop).
        let timeout = IdleStop.timeout(config: env.idleStop)
        var tracker = timeout.map { IdleStop.Tracker(timeout: $0) }
        var last = Date.distantPast
        let project = engine.project
        let tick: () -> Bool = {
            guard tracker != nil, Date().timeIntervalSince(last) >= 60 else { return false }
            let interval = last == .distantPast ? 0 : Date().timeIntervalSince(last)
            last = Date()
            let sessions = IdleStop.activeSessions(project).count
            let tunnels = TunnelStore().list().filter { $0.spec.projectRoot == project.root.path }.count
            guard tracker!.check(now: Date(), sessions: sessions, tunnels: tunnels,
                                 cpuUsec: runtime.stats(of: name)?.cpuUsageUsec, interval: interval) else { return false }
            say("idle for \(TunnelPlan.describe(seconds: tracker!.timeout)); stopping \(project.name)'s VMs (the next command starts them again)")
            try? IdleStop.recordStop(project)
            try? engine.down(remove: false)
            return true
        }
        FileRelay.supervise(project: project, containerName: name, workspace: env.workspaceFolder,
                            isRunning: { runtime.status(of: name) == .running }, tick: tick, say: say)
    }
}

/// Adds the shell hook behind the scenes the first time it's needed, so `npm` in a project
/// folder runs in its VM without anyone knowing about `titan hook`.
func ensureShellHook(_ c: Console, dryRun: Bool) {
    guard !dryRun else { return }
    let env = ProcessInfo.processInfo.environment
    let shell = URL(fileURLWithPath: env["SHELL"] ?? "/bin/zsh").lastPathComponent
    let home = env["HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    let hook = ShellSetup.ensureInstalled(shell: shell, home: home, titan: titanExecutablePath)
    if case .added(let rc) = hook {
        c.info("  Set up \(rc.lastPathComponent) so commands like npm run in the VM (new terminals; this one: exec $SHELL)")
    }
    // Global shims on PATH for every shell (coding agents, scripts), same opt-outs as the hook.
    guard hook != .skipped, !GlobalShims.isInstalled(shell: shell, home: home) else { return }
    let dir = TitanPaths.standard.shims
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let changed = try? GlobalShims.installPath(shell: shell, home: home, dir: dir.path), !changed.isEmpty {
        c.info("  Set up \(changed.map(\.lastPathComponent).joined(separator: ", ")) so coding agents and scripts run project commands in the VM too")
    }
}

/// Writes the "Dev environment" notes for coding agents (AGENTS.md + a CLAUDE.md link).
/// `ask`: existing repos get a question first (it adds files to the repo); no terminal → a tip.
func writeAgentNotes(engine: Engine, env: ResolvedEnvironment, ask: Bool, console c: Console) {
    guard !AgentNotes.hasBlock(engine.project) else { return }
    if ask {
        guard isatty(0) == 1 else {
            c.info("  Tip: `titan agents` adds notes for coding agents (AGENTS.md, CLAUDE.md).")
            return
        }
        print("Add notes for coding agents (Claude Code, Codex, Cursor) to AGENTS.md / CLAUDE.md? [Y/n] ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard answer.isEmpty || answer == "y" || answer == "yes" else { return }
    }
    if let changed = try? AgentNotes.write(project: engine.project, env: env, ports: engine.publishedPorts(env)), !changed.isEmpty {
        c.info("  Wrote notes for coding agents: \(changed.map(\.lastPathComponent).joined(separator: ", "))")
    }
}

struct Agents: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tell coding agents (Claude Code, Codex, Cursor) how this project runs (AGENTS.md, CLAUDE.md).",
        discussion: """
        Writes a short "Dev environment" section to AGENTS.md: commands run in the project's VM, \
        services and ports, and what not to do (install runtimes on the Mac, delete data). CLAUDE.md \
        gets `@AGENTS.md` so Claude Code reads it too. Only Titan's fenced section is touched; \
        `titan up` keeps it up to date. Commit both files so teammates' agents get them.
        """)
    @OptionGroup var global: GlobalOptions
    @Flag(help: "Remove Titan's section (and the files, if nothing else is in them).") var remove = false

    func run() throws {
        let engine = global.engine()
        let c = engine.console
        try guarded(c) {
            if remove {
                try AgentNotes.remove(engine.project)
                c.success("Removed Titan's notes for coding agents.")
                return
            }
            let env = try engine.resolve()
            let changed = try AgentNotes.write(project: engine.project, env: env, ports: engine.publishedPorts(env))
            if changed.isEmpty { c.success("AGENTS.md is up to date.") }
            else { c.success("Wrote \(changed.map(\.lastPathComponent).joined(separator: " and ")) for coding agents.") }
        }
    }
}
