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
        var cmd = [binary, "run", "--detach", "--name", s.name]
        if let host = s.hostPath, let guest = s.guestPath { cmd += ["--volume", "\(host):\(guest)", "--workdir", guest] }
        for m in s.mounts {
            cmd += m.readOnly ? ["--mount", "type=\(m.isVolume ? "volume" : "bind"),source=\(m.hostPath),target=\(m.guestPath),readonly"]
                              : ["--volume", "\(m.hostPath):\(m.guestPath)"]
        }
        for p in s.ports { cmd += ["--publish", "127.0.0.1:\(p.host):\(p.published)"] }
        for (k, v) in s.env.sorted(by: { $0.key < $1.key }) { cmd += ["--env", "\(k)=\(v)"] }
        if let c = s.cpus { cmd += ["--cpus", String(c)] }
        if let m = s.memory { cmd += ["--memory", m] }
        return cmd + [s.image] + s.command
    }

    public func run(_ spec: RunSpec) throws {
        let r = try runner.capture(runArguments(spec))
        guard r.ok else {
            if r.stderr.contains("Address already in use") { throw TitanError.portsInUse(spec.ports.map(\.host)) }
            throw TitanError.commandFailed("container run: \(Self.errorLine(r.stderr))", r.status)
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
        if s.detach { cmd.append("--detach") }
        if let user = s.user { cmd += ["--user", user] }
        if s.interactive { cmd.append("--interactive") }
        if s.tty { cmd.append("--tty") }
        if let wd = s.workdir { cmd += ["--workdir", wd] }
        for (k, v) in s.env.sorted(by: { $0.key < $1.key }) { cmd += ["--env", "\(k)=\(v)"] }
        return cmd + [s.name] + s.command
    }

    public func exec(_ spec: ExecSpec) throws -> Int32 {
        // Detached exec prints the container name; keep that out of the user's terminal.
        if spec.detach { return try runner.capture(execArguments(spec)).status }
        return try runner.passthrough(execArguments(spec))
    }

    public func execReplacingProcess(_ spec: ExecSpec) throws -> Never {
        try runner.replaceProcess(execArguments(spec))
    }

    /// The meaningful line of `container` stderr, without the progress-bar noise.
    static func errorLine(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let meaningful = lines.filter { !$0.isEmpty && !$0.hasPrefix("[") }
        return meaningful.last { $0.hasPrefix("Error:") } ?? meaningful.last ?? "unknown error"
    }

    // MARK: Observability

    private func json(_ args: [String]) -> Any? {
        guard let r = try? runner.capture(args), r.ok else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8))
    }

    public func stats(of name: String) -> VMStats? {
        json([binary, "stats", "--no-stream", "--format", "json", name]).flatMap(Self.parseStats)
    }

    static func parseStats(_ obj: Any) -> VMStats? {
        guard let d = ((obj as? [Any])?.first ?? obj) as? [String: Any] else { return nil }
        func u(_ k: String) -> UInt64 { (d[k] as? NSNumber)?.uint64Value ?? 0 }
        return VMStats(cpuUsageUsec: u("cpuUsageUsec"), memoryUsageBytes: u("memoryUsageBytes"),
                       memoryLimitBytes: u("memoryLimitBytes"), processes: Int(u("numProcesses")),
                       blockReadBytes: u("blockReadBytes"), blockWriteBytes: u("blockWriteBytes"),
                       networkRxBytes: u("networkRxBytes"), networkTxBytes: u("networkTxBytes"))
    }

    public func resources(of name: String) -> VMResources? {
        json([binary, "inspect", name]).flatMap(Self.parseResources)
    }

    static func parseResources(_ obj: Any) -> VMResources? {
        guard let entry = ((obj as? [Any])?.first ?? obj) as? [String: Any],
              let config = entry["configuration"] as? [String: Any],
              let res = config["resources"] as? [String: Any],
              let cpus = (res["cpus"] as? NSNumber)?.intValue,
              let mem = (res["memoryInBytes"] as? NSNumber)?.uint64Value else { return nil }
        let digest = ((config["image"] as? [String: Any])?["descriptor"] as? [String: Any])?["digest"] as? String
        return VMResources(cpus: cpus, memoryBytes: mem, imageDigest: digest)
    }

    public func imageSize(digest: String) -> UInt64? {
        json([binary, "image", "list", "--format", "json"]).flatMap { Self.parseImageSize($0, digest: digest) }
    }

    static func parseImageSize(_ obj: Any, digest: String) -> UInt64? {
        for case let image as [String: Any] in (obj as? [Any]) ?? [] {
            let descriptor = (image["configuration"] as? [String: Any])?["descriptor"] as? [String: Any]
            guard descriptor?["digest"] as? String == digest else { continue }
            let variants = image["variants"] as? [[String: Any]] ?? []
            let native = variants.first { ($0["platform"] as? [String: Any])?["architecture"] as? String == "arm64" }
            return ((native ?? variants.first)?["size"] as? NSNumber)?.uint64Value
        }
        return nil
    }

    public func imageStoreUsage() -> ImageStoreUsage? {
        json([binary, "system", "df", "--format", "json"]).flatMap(Self.parseImageStoreUsage)
    }

    static func parseImageStoreUsage(_ obj: Any) -> ImageStoreUsage? {
        guard let images = (obj as? [String: Any])?["images"] as? [String: Any] else { return nil }
        func u(_ k: String) -> UInt64 { (images[k] as? NSNumber)?.uint64Value ?? 0 }
        return ImageStoreUsage(count: Int(u("total")), sizeBytes: u("sizeInBytes"), reclaimableBytes: u("reclaimable"))
    }

    // MARK: Image housekeeping

    public func listImages() -> [LocalImage]? {
        json([binary, "image", "list", "--format", "json"]).map(Self.parseImageList)
    }

    /// Groups `image list` entries (one per reference) by index digest.
    static func parseImageList(_ obj: Any) -> [LocalImage] {
        var byDigest: [String: LocalImage] = [:]
        var order: [String] = []
        for case let entry as [String: Any] in (obj as? [Any]) ?? [] {
            let config = entry["configuration"] as? [String: Any]
            guard let digest = (config?["descriptor"] as? [String: Any])?["digest"] as? String,
                  let name = config?["name"] as? String else { continue }
            if byDigest[digest] == nil {
                order.append(digest)
                byDigest[digest] = LocalImage(digest: digest, references: [],
                                              sizeBytes: parseImageSize(obj, digest: digest) ?? 0)
            }
            byDigest[digest]!.references.append(name)
        }
        return order.compactMap { byDigest[$0] }
    }

    public func imageDigestsInUse() -> Set<String>? {
        json([binary, "list", "--all", "--format", "json"]).map(Self.parseImageDigestsInUse)
    }

    static func parseImageDigestsInUse(_ obj: Any) -> Set<String> {
        var result = Set<String>()
        for case let entry as [String: Any] in (obj as? [Any]) ?? [] {
            let image = (entry["configuration"] as? [String: Any])?["image"] as? [String: Any]
            if let d = (image?["descriptor"] as? [String: Any])?["digest"] as? String { result.insert(d) }
        }
        return result
    }

    public func deleteImages(_ references: [String]) throws {
        try check([binary, "image", "delete"] + references, quiet: true)
    }

    // MARK: Overview

    public func listContainers() -> [ContainerInfo]? {
        json([binary, "list", "--all", "--format", "json"]).map(Self.parseContainerList)
    }

    static func parseContainerList(_ obj: Any) -> [ContainerInfo] {
        ((obj as? [Any]) ?? []).compactMap { item in
            guard let entry = item as? [String: Any], let config = entry["configuration"] as? [String: Any],
                  let name = config["id"] as? String else { return nil }
            let image = (config["image"] as? [String: Any])?["reference"] as? String ?? "?"
            let memory = ((config["resources"] as? [String: Any])?["memoryInBytes"] as? NSNumber)?.uint64Value ?? 0
            let ports = ((config["publishedPorts"] as? [[String: Any]]) ?? []).compactMap { p -> PortMapping? in
                guard let host = (p["hostPort"] as? NSNumber)?.intValue,
                      let guest = (p["containerPort"] as? NSNumber)?.intValue else { return nil }
                return PortMapping(host: host, guest: guest)
            }
            let raw = entry["status"]
            let state = ((raw as? [String: Any])?["state"] as? String) ?? (raw as? String)
            return ContainerInfo(name: name, image: image,
                                 status: state?.lowercased() == "running" ? .running : .stopped,
                                 memoryLimitBytes: memory, publishedPorts: ports)
        }
    }

    public func allStats() -> [String: VMStats]? {
        guard let arr = json([binary, "stats", "--no-stream", "--format", "json"]) as? [Any] else { return nil }
        var result: [String: VMStats] = [:]
        for case let entry as [String: Any] in arr {
            if let id = entry["id"] as? String, let s = Self.parseStats(entry) { result[id] = s }
        }
        return result
    }

    public func listVolumes() -> [String]? {
        guard let arr = json([binary, "volume", "list", "--format", "json"]) as? [Any] else { return nil }
        return arr.compactMap { (($0 as? [String: Any])?["configuration"] as? [String: Any])?["name"] as? String }
    }

    public func runToCompletion(image: String, mounts: [Mount], command: [String]) throws -> Int32 {
        var cmd = [binary, "run", "--rm"]
        for m in mounts {
            cmd += m.readOnly ? ["--mount", "type=volume,source=\(m.hostPath),target=\(m.guestPath),readonly"]
                              : ["--volume", "\(m.hostPath):\(m.guestPath)"]
        }
        let r = try runner.capture(cmd + [image] + command)
        return r.status
    }

    public static func logsArguments(binary: String = "container", name: String, follow: Bool, lines: Int?, boot: Bool) -> [String] {
        var cmd = [binary, "logs"]
        if boot { cmd.append("--boot") }
        if follow { cmd.append("--follow") }
        if let lines { cmd += ["-n", String(lines)] }
        return cmd + [name]
    }

    public func logs(of name: String, follow: Bool, lines: Int?, boot: Bool) throws -> Int32 {
        try runner.passthrough(Self.logsArguments(binary: binary, name: name, follow: follow, lines: lines, boot: boot))
    }

    // MARK: Services

    public func volumeExists(_ name: String) -> Bool {
        (try? runner.capture([binary, "volume", "inspect", name]))?.ok ?? false
    }

    public func createVolume(_ name: String) throws { try check([binary, "volume", "create", name], quiet: true) }
    public func deleteVolume(_ name: String) throws { try check([binary, "volume", "delete", name], quiet: true) }

    public func ipAddress(of name: String) -> String? {
        json([binary, "inspect", name]).flatMap(Self.parseIPAddress)
    }

    static func parseIPAddress(_ obj: Any) -> String? {
        guard let entry = ((obj as? [Any])?.first ?? obj) as? [String: Any],
              let networks = (entry["status"] as? [String: Any])?["networks"] as? [[String: Any]],
              let cidr = networks.first?["ipv4Address"] as? String else { return nil }
        return cidr.split(separator: "/").first.map(String.init)
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
