import Foundation

/// The subset of the Dev Container spec (containers.dev) Titan understands.
/// Unknown keys are ignored so existing devcontainer.json files keep working.
public struct DevContainerConfig: Decodable, Equatable, Sendable {
    public struct Build: Decodable, Equatable, Sendable {
        public var dockerfile: String?
        public var context: String?
        public var args: [String: String]?
    }

    public struct TitanCustomizations: Decodable, Equatable, Sendable {
        /// Commands that the shell hook transparently routes into the VM.
        public var shims: [String]?
        public var cpus: Int?
        public var memory: String?
        /// Share npm/pip/Go module caches with other VMs (default true).
        public var sharedCache: Bool?
        /// Fail instead of picking another host port when a forwarded port is busy.
        public var strictPorts: Bool?
        /// Databases, caches etc., each in its own VM, reachable from the app by name.
        public var services: ServicesConfig?
    }

    public var name: String?
    public var image: String?
    public var build: Build?
    public var workspaceFolder: String?
    public var forwardPorts: [Int]?
    public var containerEnv: [String: String]?
    public var remoteEnv: [String: String]?
    public var postCreateCommand: LifecycleCommand?
    public var postStartCommand: LifecycleCommand?
    public var titan: TitanCustomizations?
    public var usesCompose: Bool
    /// Dev Container features; Titan serves node/python from its toolchain store.
    public var features: [String: FeatureOptions]?

    enum CodingKeys: String, CodingKey {
        case name, image, build, workspaceFolder, forwardPorts, containerEnv, remoteEnv
        case postCreateCommand, postStartCommand, customizations, dockerComposeFile, features
    }

    struct Customizations: Decodable { var titan: TitanCustomizations? }

    /// forwardPorts entries may be numbers or "host:port" strings.
    struct PortValue: Decodable {
        var port: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { port = n; return }
            if let s = try? c.decode(String.self) {
                port = Int(s.split(separator: ":").last.map(String.init) ?? s)
                return
            }
            port = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        build = try c.decodeIfPresent(Build.self, forKey: .build)
        workspaceFolder = try c.decodeIfPresent(String.self, forKey: .workspaceFolder)
        forwardPorts = try c.decodeIfPresent([PortValue].self, forKey: .forwardPorts)?.compactMap(\.port)
        containerEnv = try c.decodeIfPresent([String: String].self, forKey: .containerEnv)
        remoteEnv = try c.decodeIfPresent([String: String?].self, forKey: .remoteEnv)?.compactMapValues { $0 }
        postCreateCommand = try c.decodeIfPresent(LifecycleCommand.self, forKey: .postCreateCommand)
        postStartCommand = try c.decodeIfPresent(LifecycleCommand.self, forKey: .postStartCommand)
        titan = try c.decodeIfPresent(Customizations.self, forKey: .customizations)?.titan
        usesCompose = c.contains(.dockerComposeFile)
        features = try c.decodeIfPresent([String: FeatureOptions].self, forKey: .features)
    }

    public static func parse(_ text: String) throws -> DevContainerConfig {
        try JSONDecoder().decode(DevContainerConfig.self, from: Data(JSONC.strip(text).utf8))
    }
}

/// Lifecycle commands: a shell string, an argv array, or a named map of either.
public indirect enum LifecycleCommand: Decodable, Equatable, Sendable {
    case shell(String)
    case exec([String])
    case parallel([String: LifecycleCommand])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .shell(s); return }
        if let a = try? c.decode([String].self) { self = .exec(a); return }
        if let m = try? c.decode([String: LifecycleCommand].self) { self = .parallel(m); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected string, array or object")
    }

    /// Flattened argv steps. Named ("parallel") commands run sequentially in key order for now.
    public var steps: [[String]] {
        switch self {
        case .shell(let s): return s.isEmpty ? [] : [["/bin/sh", "-c", s]]
        case .exec(let a): return a.isEmpty ? [] : [a]
        case .parallel(let m): return m.keys.sorted().flatMap { m[$0]!.steps }
        }
    }
}
