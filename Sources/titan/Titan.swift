import ArgumentParser
import Foundation
import TitanCore

@main
struct Titan: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "titan",
        abstract: "Per-project Linux VMs on your Mac, powered by Apple's container runtime.",
        discussion: """
        Quick start:
          titan up                     create this project's VM (zero config)
          titan run -- npm test        run a command inside it
          eval "$(titan hook zsh)"     then just type `npm test` in the project
        """,
        version: "0.1.0",
        subcommands: [Init.self, Up.self, Run.self, Shell.self, Down.self, Rebuild.self,
                      Status.self, Stats.self, GC.self, Cache.self, Doctor.self, Lock.self, Hook.self, VSCode.self])

    /// Accept git-style global options before the subcommand (`titan -C dir up`).
    static func main() {
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
        return [args[i]] + globals + args[(i + 1)...]
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

    func engine(quiet: Bool = false) -> Engine {
        let console = console(quiet: quiet)
        let runner: CommandRunner = dryRun ? DryRunRunner(console: Console(verbose: verbose)) : ProcessRunner()
        return Engine(project: Project.discover(from: URL(fileURLWithPath: cwd)),
                      runtime: AppleContainerRuntime(runner: runner),
                      console: console,
                      titanExecutable: titanExecutablePath,
                      persist: !dryRun)
    }
}

var titanExecutablePath: String {
    Bundle.main.executableURL?.standardizedFileURL.path ?? CommandLine.arguments[0]
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

        if let existing = project.devcontainerURL, !force {
            console.warn("\(existing.path) already exists (use --force to overwrite).")
            throw ExitCode.failure
        }
        let url = project.root.appendingPathComponent(".devcontainer/devcontainer.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        console.success("Wrote \(url.path)")
        console.info("  Next: titan up")
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
        discussion: "Example: titan run -- npm test")

    @OptionGroup var global: GlobalOptions
    @Flag(help: .hidden) var shim = false
    @Argument(parsing: .captureForPassthrough, help: "Command and arguments.") var command: [String] = []

    func run() throws {
        let args = command.first == "--" ? Array(command.dropFirst()) : command
        let engine = global.engine(quiet: shim && !global.verbose)
        try guarded(engine.console) { try engine.run(args, cwd: FileManager.default.currentDirectoryPath) }
    }
}

struct Shell: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open an interactive shell inside the project's VM.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        let engine = global.engine()
        try guarded(engine.console) { try engine.shell(cwd: FileManager.default.currentDirectoryPath) }
    }
}

struct Down: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the project's VM.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("rm"), help: "Delete the VM instead of just stopping it.") var remove = false

    func run() throws {
        let engine = global.engine()
        try guarded(engine.console) { try engine.down(remove: remove) }
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
            let ports = r.status == .missing ? env.ports.map(PortMapping.same) : engine.publishedPorts(env)
            if !ports.isEmpty { print("ports     \(ports.map(\.description).joined(separator: ", "))") }
            if !env.shims.isEmpty { print("shims     \(env.shims.joined(separator: " "))") }
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
        if r.drifted { c.warn("Config changed since the VM was created. Run `titan rebuild`.") }
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

struct GC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Delete images that no Titan project or VM needs any more.",
        discussion: """
        Keeps images used by any VM and images pinned or used by projects you've run `titan up` in.
        By default only images Titan pulled or built are removed; --all also removes other unused images.
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
            guard !remove.isEmpty else { c.success("Nothing to remove."); return }
            let download = remove.reduce(0) { $0 + $1.sizeBytes }
            print("\n\(remove.count) image(s), \(f(download)) download size (plus their unpacked copies on disk).")
            if global.dryRun { print(c.paint("--dry-run: nothing deleted.", "2")); return }
            guard confirm("Delete them?", yes: yes, console: c) else { return }
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
    static let configuration = CommandConfiguration(abstract: "Show or refresh the image pin in titan.lock.")
    @OptionGroup var global: GlobalOptions
    @Flag(help: "Re-pull the image tag and pin its current digest.") var update = false

    func run() throws {
        let engine = global.engine()
        let c = engine.console
        try guarded(c) {
            let env = try engine.resolve()
            guard case .pull(let ref) = env.image else {
                c.info("This project builds its image from a Dockerfile; nothing to pin.")
                return
            }
            if !update {
                if let lock = Lockfile.load(engine.project) { print(lock.pinnedReference) } else { c.info("No titan.lock yet. Run `titan up` or `titan lock --update`.") }
                return
            }
            guard engine.runtime.isInstalled() else { throw TitanError.runtimeMissing }
            try engine.runtime.pull(ref)
            let lock = Lockfile(image: ref, digest: engine.runtime.imageDigest(ref))
            try lock.save(engine.project)
            c.success("Pinned \(lock.pinnedReference)")
        }
    }
}

struct Hook: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the shell hook. Add `eval \"$(titan hook zsh)\"` to ~/.zshrc.")
    @Argument(help: "zsh or bash") var shell: String = "zsh"

    func run() throws {
        guard let script = ShellHook.script(for: shell) else {
            throw ValidationError("Unsupported shell '\(shell)'. Use zsh or bash.")
        }
        print(script)
    }
}

struct VSCode: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vscode", abstract: "Make VS Code's integrated terminal open inside the VM.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        let console = global.console()
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
