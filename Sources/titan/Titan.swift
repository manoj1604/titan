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
                      Status.self, Doctor.self, Lock.self, Hook.self, VSCode.self])

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
        if !env.ports.isEmpty {
            c.info("  ports    " + env.ports.map { "http://localhost:\($0)" }.joined(separator: "  "))
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
            if !env.ports.isEmpty { print("ports     \(env.ports.map(String.init).joined(separator: ", "))") }
            if !env.shims.isEmpty { print("shims     \(env.shims.joined(separator: " "))") }
        } else if let err = r.environmentError {
            print("config    \(c.paint("error: " + err, "31"))")
        }
        if let lock = r.lock { print("lock      \(lock.pinnedReference)") }
        if r.drifted { c.warn("Config changed since the VM was created. Run `titan rebuild`.") }
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
