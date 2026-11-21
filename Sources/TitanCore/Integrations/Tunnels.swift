import Foundation

/// What to share: one project port through a Cloudflare tunnel, optionally on the user's own
/// domain, behind a password, for a limited time.
public struct TunnelSpec: Codable, Equatable, Sendable {
    public var projectRoot: String
    public var projectName: String
    public var containerName: String
    /// The port the app listens on in the VM, and where it's published on the Mac.
    public var guestPort: Int
    public var hostPort: Int
    /// nil: a quick tunnel (random *.trycloudflare.com). Otherwise the user's own hostname.
    public var domain: String?
    public var password: String?
    public var ttlSeconds: Int?
    public var keepHost: Bool = false
    /// Where the app is reached from the Mac: 127.0.0.1 (a forwarded port, `hostPort` on the Mac)
    /// or the VM's own address for ports that were never forwarded (nil = 127.0.0.1).
    public var upstreamHost: String?

    public var upstream: String { "http://\(upstreamHost ?? "127.0.0.1"):\(hostPort)" }

    public init(projectRoot: String, projectName: String, containerName: String, guestPort: Int, hostPort: Int,
                domain: String? = nil, password: String? = nil, ttlSeconds: Int? = nil, keepHost: Bool = false,
                upstreamHost: String? = nil) {
        self.projectRoot = projectRoot
        self.projectName = projectName
        self.containerName = containerName
        self.guestPort = guestPort
        self.hostPort = hostPort
        self.domain = domain
        self.password = password
        self.ttlSeconds = ttlSeconds
        self.keepHost = keepHost
        self.upstreamHost = upstreamHost
    }

    public var id: String { "\(containerName)-\(guestPort)" }
}

/// A running tunnel, written by its supervisor so other titan commands can show and stop it.
public struct TunnelRecord: Codable, Equatable, Sendable {
    public var spec: TunnelSpec
    /// The supervisor process (the one to signal to stop the tunnel).
    public var pid: Int32
    public var url: String?
    public var startedAt: Date
    public var expiresAt: Date?
    public var visitLog: String

    public init(spec: TunnelSpec, pid: Int32, url: String?, startedAt: Date, expiresAt: Date?, visitLog: String) {
        self.spec = spec
        self.pid = pid
        self.url = url
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.visitLog = visitLog
    }
}

/// Tunnel state files live in `<support>/tunnels/`: `<id>.json` while a tunnel runs.
public struct TunnelStore: Sendable {
    public let paths: TitanPaths
    public init(paths: TitanPaths = .standard) { self.paths = paths }

    public var directory: URL { paths.support.appendingPathComponent("tunnels") }
    func recordURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    public func visitLog(_ id: String) -> URL { directory.appendingPathComponent("\(id).visits.log") }
    public func specURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).spec.json") }
    public func supervisorLog(_ id: String) -> URL { directory.appendingPathComponent("\(id).log") }

    func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    public func save(_ record: TunnelRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = recordURL(record.spec.id)
        try coder().0.encode(record).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)  // may hold a password
    }

    public func remove(_ id: String) { try? FileManager.default.removeItem(at: recordURL(id)) }

    public func saveSpec(_ spec: TunnelSpec) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = specURL(spec.id)
        try coder().0.encode(spec).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public func loadSpec(_ url: URL) throws -> TunnelSpec {
        try coder().1.decode(TunnelSpec.self, from: Data(contentsOf: url))
    }

    /// Running tunnels; records whose supervisor is gone are cleaned up.
    public func list(alive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> [TunnelRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".spec.json") }.sorted().compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let r = try? coder().1.decode(TunnelRecord.self, from: data) else { return nil }
            guard alive(r.pid) else { try? FileManager.default.removeItem(at: url); return nil }
            return r
        }
    }

    public func record(_ id: String) -> TunnelRecord? { list().first { $0.spec.id == id } }
}

/// Domains a project should keep, remembered on this Mac (never committed: teammates have
/// their own). `<support>/domains.json`: project root → port → choice.
public struct DomainChoices: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        public var domain: String
        /// Bring the tunnel up whenever the project's VM is up (`titan up`).
        public var always: Bool
        /// Keep the password across restarts (only stored when the user asked for one).
        public var password: String?

        public init(domain: String, always: Bool, password: String?) {
            self.domain = domain
            self.always = always
            self.password = password
        }
    }
    public var projects: [String: [String: Choice]] = [:]

    public init() {}

    static func url(_ paths: TitanPaths) -> URL { paths.support.appendingPathComponent("domains.json") }

    public static func load(_ paths: TitanPaths) -> DomainChoices {
        guard let data = try? Data(contentsOf: url(paths)) else { return DomainChoices() }
        return (try? JSONDecoder().decode(DomainChoices.self, from: data)) ?? DomainChoices()
    }

    public func save(_ paths: TitanPaths) throws {
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.url(paths), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url(paths).path)
    }

    public func choice(_ project: Project, port: Int) -> Choice? { projects[project.root.path]?[String(port)] }

    public mutating func set(_ project: Project, port: Int, _ choice: Choice?) {
        var ports = projects[project.root.path] ?? [:]
        ports[String(port)] = choice
        projects[project.root.path] = ports.isEmpty ? nil : ports
    }
}

/// Helpers for `titan share`.
public enum TunnelPlan {
    /// "90s", "30m", "2h", "1d" → seconds.
    public static func parseDuration(_ text: String) -> Int? {
        guard let m = text.lowercased().wholeMatch(of: /(\d+)\s*(s|m|h|d)?/), let n = Int(m.1), n > 0 else { return nil }
        switch m.2 { case "m": return n * 60; case "h": return n * 3600; case "d": return n * 86400; default: return n }
    }

    public static func describe(seconds: Int) -> String {
        if seconds % 86400 == 0 { return "\(seconds / 86400)d" }
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    /// A password that's easy to read out and type: four groups of four letters/digits.
    public static func generatePassword() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")  // no 0/o, 1/l/i
        var rng = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String((0..<4).map { _ in chars.randomElement(using: &rng)! }) }.joined(separator: "-")
    }

    public static func isValidDomain(_ d: String) -> Bool {
        d.count <= 253 && d.wholeMatch(of: /([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}/) != nil
    }

    /// Tunnel name for a domain in the user's Cloudflare account: "titan-shop-example-com".
    public static func tunnelName(for domain: String) -> String {
        "titan-" + domain.replacingOccurrences(of: ".", with: "-")
    }

    /// cloudflared arguments for the tunnel in front of the gate (or the app, without a gate).
    public static func cloudflaredArguments(spec: TunnelSpec, target: String, rewriteHostWithoutGate: Bool) -> [String] {
        if let domain = spec.domain {
            return ["tunnel", "--no-autoupdate", "run", "--url", target, tunnelName(for: domain)]
        }
        var args = ["tunnel", "--no-autoupdate", "--url", target]
        if rewriteHostWithoutGate { args += ["--http-host-header", "localhost:\(spec.guestPort)"] }
        return args
    }

    /// The gate's arguments (the password goes in the environment, not `ps`).
    public static func gateArguments(spec: TunnelSpec, visitLog: String) -> [String] {
        var args = ["-upstream", spec.upstream, "-name", spec.projectName, "-log", visitLog]
        if !spec.keepHost { args += ["-host", "localhost:\(spec.guestPort)"] }
        return args
    }

    /// The gate binary installed next to the forwarder.
    public static func gateBinary(executable: String) -> String? {
        guard let dir = Forwarder.shareDirectory(executable: executable) else { return nil }
        let path = dir.appendingPathComponent("titan-gate").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// True once cloudflared logs a live connection to Cloudflare's edge (named tunnels).
    public static func isConnected(_ line: String) -> Bool { line.contains("Registered tunnel connection") }
}

/// Setting up a named tunnel on the user's own domain (needs `cloudflared tunnel login` once).
public struct NamedTunnelSetup: Sendable {
    let runner: CommandRunner
    let cloudflared: String
    let home: URL

    public init(runner: CommandRunner, cloudflared: String,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.runner = runner
        self.cloudflared = cloudflared
        self.home = home
    }

    public var isLoggedIn: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".cloudflared/cert.pem").path)
    }

    /// Finds the tunnel for `domain` in the user's account, or creates it. Returns its name.
    public func ensureTunnel(for domain: String, console: Console) throws -> String {
        let name = TunnelPlan.tunnelName(for: domain)
        let list = try runner.capture([cloudflared, "tunnel", "list", "--output", "json", "--name", name])
        if list.ok, let data = list.stdout.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           arr.contains(where: { ($0["name"] as? String) == name && ($0["deleted_at"] as? String).map { $0.hasPrefix("0001") } ?? true }) {
            return name
        }
        console.step("Creating Cloudflare tunnel \(name)")
        let created = try runner.capture([cloudflared, "tunnel", "create", name])
        guard created.ok else {
            throw TitanError.message("Couldn't create the tunnel: \(Self.lastLine(created.stderr + created.stdout))")
        }
        return name
    }

    /// Points `domain` at the tunnel. Refuses to replace an existing DNS record (that could
    /// take down a live site); the user picks another name or removes the record.
    public func routeDNS(_ domain: String, to tunnel: String, console: Console) throws {
        console.step("Pointing \(domain) at the tunnel")
        let r = try runner.capture([cloudflared, "tunnel", "route", "dns", tunnel, domain])
        let text = r.stdout + r.stderr
        if r.ok { return }
        if text.contains("already exists") || text.contains("record with that host already exists") {
            // Fine if it already points at this tunnel (e.g. a second run); cloudflared says so on success,
            // so an "exists" error means it points elsewhere.
            throw TitanError.message("A DNS record for \(domain) already exists in Cloudflare and points somewhere else. "
                                     + "Pick another name (e.g. dev.\(domain)) or delete that record in the Cloudflare dashboard.")
        }
        throw TitanError.message("Couldn't add the DNS record for \(domain): \(Self.lastLine(text))")
    }

    static func lastLine(_ text: String) -> String {
        text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "unknown error"
    }
}
