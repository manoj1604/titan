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

    public init(image: String, digest: String?) {
        self.image = image
        self.digest = digest
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
