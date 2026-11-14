import Foundation

/// Where Titan keeps machine-wide (not per-project) data.
public struct TitanPaths: Sendable, Equatable {
    /// Durable data, e.g. the project registry.
    public var support: URL
    /// Disposable data, e.g. shared package caches.
    public var caches: URL

    public init(support: URL, caches: URL) {
        self.support = support
        self.caches = caches
    }

    /// `~/Library/Application Support/titan` and `~/Library/Caches/titan`, or `$TITAN_HOME/...`.
    public static var standard: TitanPaths {
        if let home = ProcessInfo.processInfo.environment["TITAN_HOME"], !home.isEmpty {
            let url = URL(fileURLWithPath: home)
            return TitanPaths(support: url, caches: url.appendingPathComponent("caches"))
        }
        let lib = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return TitanPaths(support: lib.appendingPathComponent("Application Support/titan"),
                          caches: lib.appendingPathComponent("Caches/titan"))
    }

    public var registryURL: URL { support.appendingPathComponent("projects.json") }
    /// Host folder mounted into every VM at `SharedCache.guestPath`.
    public var sharedCache: URL { caches.appendingPathComponent("shared") }
}

/// Every project that has had a VM on this Mac, so `titan gc` knows which images are still needed.
public struct Registry: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var lastUsed: Date
        /// Image references this project's VMs were created from (pulled or built by Titan).
        public var images: [String]
    }

    public var projects: [String: Entry] = [:]

    public init() {}

    public static func load(_ paths: TitanPaths) -> Registry {
        guard let data = try? Data(contentsOf: paths.registryURL) else { return Registry() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(Registry.self, from: data)) ?? Registry()
    }

    public func save(_ paths: TitanPaths) throws {
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        try (e.encode(self) + Data("\n".utf8)).write(to: paths.registryURL, options: .atomic)
    }

    public mutating func record(_ project: Project, image: String?, at date: Date = Date()) {
        var entry = projects[project.root.path] ?? Entry(lastUsed: date, images: [])
        entry.lastUsed = date
        if let image, !entry.images.contains(image) { entry.images.append(image) }
        projects[project.root.path] = entry
    }

    /// Projects whose folder still exists.
    public var liveProjects: [Project] {
        projects.keys.sorted()
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { Project(root: URL(fileURLWithPath: $0)) }
    }

    /// Every image reference Titan has ever created a VM from.
    public var allImages: Set<String> { Set(projects.values.flatMap(\.images)) }
}
