import Foundation

/// Backend that shells out to Apple's `container` CLI (github.com/apple/container).
public struct AppleContainerRuntime: ContainerRuntime {
    let runner: CommandRunner
    let binary: String

    public init(runner: CommandRunner, binary: String = "container") {
        self.runner = runner
        self.binary = binary
    }

    public var displayName: String { "Apple container" }

    public func isInstalled() -> Bool { runner.which(binary) != nil }

    public func version() -> String? {
        guard let r = try? runner.capture([binary, "--version"]), r.ok else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isSystemRunning() -> Bool {
        (try? runner.capture([binary, "system", "status"]))?.ok ?? false
    }

    public func startSystem() throws {
        // First start asks whether to install the default kernel; without a TTY that prompt would hang.
        var args = [binary, "system", "start"]
        if isatty(0) != 1 { args.append("--enable-kernel-install") }
        let code = try runner.passthrough(args)
        guard code == 0 else { throw TitanError.systemStartFailed(code) }
    }

    public func status(of name: String) -> ContainerStatus {
        guard let r = try? runner.capture([binary, "inspect", name]), r.ok else { return .missing }
        return Self.parseStatus(r.stdout)
    }

    static func parseStatus(_ json: String) -> ContainerStatus {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return .missing }
        if let arr = obj as? [Any], arr.isEmpty { return .missing }
        let entry = (obj as? [Any])?.first ?? obj
        // container 1.7+: "status": {"state": "running", "networks": [...]}; older: "status": "running".
        let raw = (entry as? [String: Any])?["status"]
        let state = ((raw as? [String: Any])?["state"] as? String) ?? (raw as? String)
        return state?.lowercased() == "running" ? .running : .stopped
    }

    /// Pull only the platform we can run; by default `container image pull` unpacks every platform.
    public static let platform = "linux/arm64"

    public func pull(_ reference: String) throws {
        try check([binary, "image", "pull", "--platform", Self.platform, reference])
    }

    public func build(tag: String, dockerfile: String, context: String, args: [String: String]) throws {
        var cmd = [binary, "build", "--tag", tag, "--file", dockerfile]
        for (k, v) in args.sorted(by: { $0.key < $1.key }) { cmd += ["--build-arg", "\(k)=\(v)"] }
        try check(cmd + [context])
    }

    public func imageDigest(_ reference: String) -> String? {
        guard let r = try? runner.capture([binary, "image", "inspect", reference]), r.ok,
              let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)),
              let digest = Self.findValue(forKey: "digest", in: obj) as? String,
              digest.hasPrefix("sha256:") else { return nil }
        return digest
    }

    public func runArguments(_ s: RunSpec) -> [String] {
        var cmd = [binary, "run", "--detach", "--name", s.name,
                   "--volume", "\(s.hostPath):\(s.guestPath)", "--workdir", s.guestPath]
        for p in s.ports { cmd += ["--publish", "127.0.0.1:\(p):\(p)"] }
        for (k, v) in s.env.sorted(by: { $0.key < $1.key }) { cmd += ["--env", "\(k)=\(v)"] }
        if let c = s.cpus { cmd += ["--cpus", String(c)] }
        if let m = s.memory { cmd += ["--memory", m] }
        return cmd + [s.image] + s.command
    }

    public func run(_ spec: RunSpec) throws {
        let r = try runner.capture(runArguments(spec))
        guard r.ok else {
            throw TitanError.commandFailed("container run (\(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))", r.status)
        }
    }

    public func start(_ name: String) throws { try check([binary, "start", name], quiet: true) }
    public func stop(_ name: String) throws { try check([binary, "stop", name], quiet: true) }

    public func remove(_ name: String) throws {
        if status(of: name) == .running { try stop(name) }
        try check([binary, "delete", name], quiet: true)
    }

    public func execArguments(_ s: ExecSpec) -> [String] {
        var cmd = [binary, "exec"]
        if s.interactive { cmd.append("--interactive") }
        if s.tty { cmd.append("--tty") }
        if let wd = s.workdir { cmd += ["--workdir", wd] }
        for (k, v) in s.env.sorted(by: { $0.key < $1.key }) { cmd += ["--env", "\(k)=\(v)"] }
        return cmd + [s.name] + s.command
    }

    public func exec(_ spec: ExecSpec) throws -> Int32 {
        try runner.passthrough(execArguments(spec))
    }

    public func execReplacingProcess(_ spec: ExecSpec) throws -> Never {
        try runner.replaceProcess(execArguments(spec))
    }

    private func check(_ args: [String], quiet: Bool = false) throws {
        let code: Int32
        if quiet {
            let r = try runner.capture(args)
            code = r.status
        } else {
            code = try runner.passthrough(args)
        }
        guard code == 0 else { throw TitanError.commandFailed(args.prefix(3).joined(separator: " "), code) }
    }

    /// Depth-first search for the first value stored under `key`.
    static func findValue(forKey key: String, in obj: Any) -> Any? {
        if let dict = obj as? [String: Any] {
            if let v = dict[key] { return v }
            for k in dict.keys.sorted() { if let v = findValue(forKey: key, in: dict[k]!) { return v } }
        } else if let arr = obj as? [Any] {
            for item in arr { if let v = findValue(forKey: key, in: item) { return v } }
        }
        return nil
    }
}
