import Foundation

/// Machine-local state (gitignored, in .titan/).
public struct ProjectState: Codable, Equatable, Sendable {
    public var containerName: String
    /// Hash of the resolved environment the current VM was created from.
    public var configHash: String?
    /// Hash for which postCreate completed successfully.
    public var postCreateHash: String?
    public var image: String?
    /// Ports the current VM publishes (host side may differ from the config when a port was busy).
    public var ports: [PortMapping]?
    /// The Linux user set up in the current VM (nil: commands run as root). Older VMs have
    /// none, so Titan keeps using root there until `titan up --rebuild`.
    public var user: String?
    /// Per-service state, keyed by service name.
    public var services: [String: ServiceState]?

    public struct ServiceState: Codable, Equatable, Sendable {
        public var configHash: String
        public var image: String
        public var ports: [PortMapping]
    }

    public init(containerName: String) { self.containerName = containerName }

    static func url(_ p: Project) -> URL { p.stateDir.appendingPathComponent("state.json") }

    public static func load(_ p: Project) -> ProjectState? {
        guard let data = try? Data(contentsOf: url(p)) else { return nil }
        return try? JSONDecoder().decode(ProjectState.self, from: data)
    }

    public func save(_ p: Project) throws {
        try Persistence.ensureStateDir(p)
        try Persistence.encode(self).write(to: ProjectState.url(p), options: .atomic)
    }
}

/// Committed to the repo: pins the exact image so every machine runs the same bits.
public struct Lockfile: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var image: String
    public var digest: String?
    /// Service images pinned the same way, keyed by service name (omitted when there are none).
    public var services: [String: Pin]?
    /// Toolchain source images pinned the same way, keyed by toolchain kind.
    public var toolchains: [String: Pin]?

    public struct Pin: Codable, Equatable, Sendable {
        public var image: String
        public var digest: String
        public var pinnedReference: String { "\(image)@\(digest)" }
    }

    public init(image: String, digest: String?, services: [String: Pin]? = nil) {
        self.image = image
        self.digest = digest
        self.services = services
    }

    /// The reference to actually pull: digest-pinned when known.
    public var pinnedReference: String {
        guard let digest else { return image }
        return "\(image)@\(digest)"
    }

    public static func load(_ p: Project) -> Lockfile? {
        guard let data = try? Data(contentsOf: p.lockfileURL) else { return nil }
        return try? JSONDecoder().decode(Lockfile.self, from: data)
    }

    public func save(_ p: Project) throws {
        try Persistence.encode(self).write(to: p.lockfileURL, options: .atomic)
    }
}

enum Persistence {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(value) + Data("\n".utf8)
    }

    static func ensureStateDir(_ p: Project) throws {
        try FileManager.default.createDirectory(at: p.stateDir, withIntermediateDirectories: true)
        let ignore = p.stateDir.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try Data("# Machine-local Titan state\n*\n".utf8).write(to: ignore)
        }
    }
}
