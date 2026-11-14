import Foundation

/// One `customizations.titan.services` entry as written: an image or preset string
/// ("postgres", "redis:7") or an object with overrides.
public struct ServiceConfig: Decodable, Equatable, Sendable {
    public var image: String?
    public var port: Int?
    public var env: [String: String]?
    /// Directory inside the service kept on a persistent volume.
    public var data: String?
    public var command: [String]?

    public init(image: String? = nil, port: Int? = nil, env: [String: String]? = nil,
                data: String? = nil, command: [String]? = nil) {
        self.image = image
        self.port = port
        self.env = env
        self.data = data
        self.command = command
    }

    enum CodingKeys: String, CodingKey { case image, port, env, data, command }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.init(image: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(image: try c.decodeIfPresent(String.self, forKey: .image),
                  port: try c.decodeIfPresent(Int.self, forKey: .port),
                  env: try c.decodeIfPresent([String: String].self, forKey: .env),
                  data: try c.decodeIfPresent(String.self, forKey: .data),
                  command: try c.decodeIfPresent([String].self, forKey: .command))
    }
}

/// `services` as written: `["postgres", "redis"]` or `{"db": "postgres:16", "cache": {...}}`.
public struct ServicesConfig: Decodable, Equatable, Sendable {
    public var entries: [(name: String, config: ServiceConfig)]

    public static func == (a: ServicesConfig, b: ServicesConfig) -> Bool {
        a.entries.map(\.name) == b.entries.map(\.name) && a.entries.map(\.config) == b.entries.map(\.config)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let list = try? c.decode([String].self) {
            entries = list.map { (ServicePreset.defaultName(for: $0), ServiceConfig(image: $0)) }
        } else {
            let map = try c.decode([String: ServiceConfig].self)
            entries = map.keys.sorted().map { ($0, map[$0]!) }
        }
    }
}

/// Sensible defaults for common services, keyed by image repository.
public struct ServicePreset: Sendable {
    public var repository: String
    public var defaultImage: String
    public var port: Int
    public var env: [String: String]
    public var data: String
    /// Variables given to the app; `{host}`, `{port}` and `{env:NAME}` (the service's final env) are filled in.
    public var appEnv: [String: String]

    public static let all: [ServicePreset] = [
        ServicePreset(repository: "postgres", defaultImage: "postgres:16-bookworm", port: 5432,
                      env: ["POSTGRES_USER": "postgres", "POSTGRES_PASSWORD": "postgres", "POSTGRES_DB": "app",
                            // The volume's root holds lost+found, which initdb refuses; use a subdirectory.
                            "PGDATA": "/var/lib/postgresql/data/pgdata"],
                      data: "/var/lib/postgresql/data",
                      appEnv: ["DATABASE_URL": "postgres://{env:POSTGRES_USER}:{env:POSTGRES_PASSWORD}@{host}:{port}/{env:POSTGRES_DB}"]),
        ServicePreset(repository: "redis", defaultImage: "redis:7-bookworm", port: 6379,
                      env: [:], data: "/data",
                      appEnv: ["REDIS_URL": "redis://{host}:{port}"]),
    ]

    static func repository(of image: String) -> String {
        let name = image.split(separator: "@").first.map(String.init) ?? image
        let last = name.split(separator: "/").last.map(String.init) ?? name
        return last.split(separator: ":").first.map(String.init) ?? last
    }

    public static func find(image: String) -> ServicePreset? {
        let repo = repository(of: image)
        return all.first { $0.repository == repo }
    }

    /// Service (and host) name for a list entry: "postgres:16" → "postgres".
    public static func defaultName(for image: String) -> String { repository(of: image) }

    /// "postgres" → "postgres:16-bookworm"; "postgres:15" stays as written.
    static func expand(_ image: String) -> String {
        guard !image.contains(":"), !image.contains("@"), let p = find(image: image) else { return image }
        return p.defaultImage
    }
}

/// A fully resolved service: everything needed to run it and wire it to the app.
public struct ResolvedService: Codable, Equatable, Sendable {
    /// Also the hostname the app uses to reach it.
    public var name: String
    public var image: String
    public var port: Int?
    public var env: [String: String]
    public var data: String?
    public var command: [String]
    public var appEnv: [String: String]

    /// Drives "service config changed" detection independently of the app VM.
    public var configHash: String {
        var copy = self
        copy.appEnv = [:]  // app-side only; changing it needn't recreate the service
        return Hashing.sha256((try? Persistence.encode(copy)) ?? Data())
    }

    public static func resolve(name: String, config: ServiceConfig) throws -> ResolvedService {
        guard name.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,30}/) != nil else {
            throw TitanError.message("Service name '\(name)' must be lowercase letters, digits and dashes "
                                     + "(it becomes the hostname the app connects to).")
        }
        guard let written = config.image, !written.isEmpty else {
            throw TitanError.message("Service '\(name)' needs an image, e.g. \"\(name)\": \"postgres:16\".")
        }
        let image = ServicePreset.expand(written)
        let preset = ServicePreset.find(image: image)
        let port = config.port ?? preset?.port
        let env = (preset?.env ?? [:]).merging(config.env ?? [:]) { _, user in user }
        var appEnv: [String: String] = [:]
        if let preset, let port {
            for (k, template) in preset.appEnv {
                var v = template.replacingOccurrences(of: "{host}", with: name)
                    .replacingOccurrences(of: "{port}", with: String(port))
                for (ek, ev) in env { v = v.replacingOccurrences(of: "{env:\(ek)}", with: ev) }
                appEnv[k] = v
            }
        }
        return ResolvedService(name: name, image: image, port: port, env: env,
                               data: config.data ?? preset?.data,
                               command: config.command ?? [], appEnv: appEnv)
    }
}
