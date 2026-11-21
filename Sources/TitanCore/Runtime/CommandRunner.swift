import Foundation

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var ok: Bool { status == 0 }
}

/// Process execution, abstracted so the runtime can be tested and dry-run.
public protocol CommandRunner: Sendable {
    /// Runs and captures output (stdin is /dev/null).
    func capture(_ args: [String]) throws -> CommandResult
    /// Runs attached to the user's terminal; returns the exit status.
    func passthrough(_ args: [String]) throws -> Int32
    /// Replaces the current process (perfect TTY, signal and exit-code passthrough).
    func replaceProcess(_ args: [String]) throws -> Never
    func which(_ name: String) -> String?
}

public struct ProcessRunner: CommandRunner {
    public init() {}

    private final class Box: @unchecked Sendable { var data = Data() }

    public func capture(_ args: [String]) throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()

        let errHandle = err.fileHandleForReading
        let errBox = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = errHandle.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return CommandResult(status: exitStatus(p),
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errBox.data, as: UTF8.self))
    }

    /// Runs attached to the terminal, in titan's own process group. Foundation's Process puts
    /// children in a new process group, so a child that reads the terminal (an interactive
    /// `container exec --tty`) isn't in the foreground: it can't read keystrokes and spins.
    /// posix_spawn without POSIX_SPAWN_SETPGROUP keeps it in the foreground group.
    public func passthrough(_ args: [String]) throws -> Int32 {
        let argv = (["/usr/bin/env"] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/usr/bin/env", nil, nil, argv, environ)
        guard rc == 0 else { throw TitanError.execFailed(args.first ?? "", String(cString: strerror(rc))) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { throw TitanError.execFailed(args.first ?? "", String(cString: strerror(errno))) }
        }
        return Self.exitCode(fromWaitStatus: status)
    }

    /// The shell's convention for a waitpid status: the exit code, or 128 + signal.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    public func replaceProcess(_ args: [String]) throws -> Never {
        precondition(!args.isEmpty)
        fflush(nil)
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        execvp(args[0], &cargs)
        let reason = String(cString: strerror(errno))
        throw TitanError.execFailed(args[0], reason)
    }

    public func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func exitStatus(_ p: Process) -> Int32 {
        p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
    }
}

/// Prints the commands Titan would run instead of running them.
public struct DryRunRunner: CommandRunner {
    let console: Console
    public init(console: Console) { self.console = console }

    public func capture(_ args: [String]) throws -> CommandResult {
        console.info(console.paint("$ " + shellJoin(args), "2"))
        return CommandResult(status: 0, stdout: "", stderr: "")
    }

    public func passthrough(_ args: [String]) throws -> Int32 {
        console.info("$ " + shellJoin(args))
        return 0
    }

    public func replaceProcess(_ args: [String]) throws -> Never {
        console.info("$ exec " + shellJoin(args))
        exit(0)
    }

    public func which(_ name: String) -> String? {
        ProcessRunner().which(name) ?? "/usr/local/bin/\(name)"
    }
}
