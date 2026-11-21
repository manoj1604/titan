import Foundation

public enum ImageSource: Codable, Equatable, Sendable {
    case pull(String)
    case build(dockerfile: String, context: String, args: [String: String], dockerfileHash: String)

    public var display: String {
        switch self {
        case .pull(let ref): return ref
        case .build(let df, _, _, _): return "build \(df)"
        }
    }
}

/// Fully resolved description of a project's VM. Its hash drives drift detection.
public struct ResolvedEnvironment: Codable, Equatable, Sendable {
    public var origin: String
    public var image: ImageSource
    public var workspaceFolder: String
    public var ports: [Int]
    public var containerEnv: [String: String]
    public var remoteEnv: [String: String]
    public var postCreate: [[String]]
    public var postStart: [[String]]
    public var shims: [String]
    public var cpus: Int?
    public var memory: String?
    /// Mount the machine-wide package cache (see SharedCache).
    public var sharedCache: Bool = true
    /// Optional so it's omitted from the encoded config (and the hash) unless set.
    public var strictPorts: Bool?
    /// "30m", "2h", "off"… (see IdleStop); not part of `configHash`.
    public var idleStop: String?
    /// Each service has its own VM and hash, so it is excluded from `configHash`:
    /// adding a database must not rebuild the app VM.
    /// Optional so it's omitted from the encoding (and existing hashes stay valid) when unset.
    public var services: [ResolvedService]?
    public var serviceList: [ResolvedService] { services ?? [] }
    /// Runtimes from the shared toolchain store (optional: omitted from the hash when unset).
    public var toolchains: [ToolchainRequest]?
    public var toolchainList: [ToolchainRequest] { toolchains ?? [] }
    /// Who runs commands: "me" (a user named after the Mac user), a user that exists in the
    /// image, or nil for the image default (root). Optional so root projects keep their hash.
    public var user: String?

    public var configHash: String {
        var copy = self
        copy.origin = ""
        copy.shims = []  // shims only affect the host side; changing them shouldn't rebuild the VM
        copy.services = nil
        copy.idleStop = nil   // a host-side setting: changing it must not rebuild the VM
        let data = (try? Persistence.encode(copy)) ?? Data()
        return Hashing.sha256(data)
    }
}

public enum EnvironmentResolver {
    public static func resolve(_ project: Project) throws -> ResolvedEnvironment {
        let detected = StackDetector.detect(at: project.root)
        guard let url = project.devcontainerURL else {
            return ResolvedEnvironment(
                origin: "detected: \(detected.kind) (\(detected.evidence.joined(separator: ", ")))",
                image: .pull(detected.image),
                workspaceFolder: project.defaultWorkspaceFolder,
                ports: detected.ports,
                containerEnv: [:], remoteEnv: [:],
                postCreate: detected.setup.isEmpty ? [] : [["/bin/sh", "-c", detected.setup.joined(separator: " && ")]],
                postStart: [],
                shims: detected.shims,
                cpus: nil, memory: nil)
        }

        let relPath = url.path.replacingOccurrences(of: project.root.path + "/", with: "")
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            throw TitanError.invalidConfig(relPath, error.localizedDescription)
        }
        let config: DevContainerConfig
        do { config = try DevContainerConfig.parse(text) } catch {
            throw TitanError.invalidConfig(relPath, "\(error)")
        }
        if config.usesCompose { throw TitanError.unsupported("dockerComposeFile in \(relPath)") }

        let image: ImageSource
        if let df = config.build?.dockerfile {
            let base = url.deletingLastPathComponent()
            let dockerfile = base.appendingPathComponent(df).standardizedFileURL
            let context = base.appendingPathComponent(config.build?.context ?? ".").standardizedFileURL
            let contents = (try? Data(contentsOf: dockerfile)) ?? Data()
            image = .build(dockerfile: dockerfile.path, context: context.path,
                           args: config.build?.args ?? [:], dockerfileHash: Hashing.sha256(contents))
        } else if let ref = config.image {
            image = .pull(ref)
        } else {
            throw TitanError.invalidConfig(relPath, "needs either \"image\" or \"build.dockerfile\"")
        }

        return ResolvedEnvironment(
            origin: relPath,
            image: image,
            workspaceFolder: config.workspaceFolder ?? project.defaultWorkspaceFolder,
            ports: config.forwardPorts ?? [],
            containerEnv: config.containerEnv ?? [:],
            remoteEnv: config.remoteEnv ?? [:],
            postCreate: config.postCreateCommand?.steps ?? [],
            postStart: config.postStartCommand?.steps ?? [],
            shims: config.titan?.shims ?? detected.shims,
            cpus: config.titan?.cpus,
            memory: config.titan?.memory,
            sharedCache: config.titan?.sharedCache ?? true,
            strictPorts: config.titan?.strictPorts,
            idleStop: config.titan?.idleStop?.text,
            services: try config.titan?.services?.entries.map { try ResolvedService.resolve(name: $0.name, config: $0.config) },
            toolchains: try config.features.flatMap { $0.isEmpty ? nil : try Toolchain.requests(from: $0) },
            // Titan's own setting wins, then the spec's remoteUser; otherwise the image default (root).
            user: VMUser.normalize(config.titan?.user ?? config.remoteUser))
    }

    /// devcontainer.json contents for `titan init`, based on detection.
    public static func generateDevcontainer(for project: Project, services: [String] = []) -> String {
        let d = StackDetector.detect(at: project.root)
        var titan: [String: Any] = ["shims": d.shims]
        if !services.isEmpty { titan["services"] = services }
        var obj: [String: Any] = [
            "name": project.name,
            "image": d.image,
            "customizations": ["titan": titan],
        ]
        if !d.ports.isEmpty { obj["forwardPorts"] = d.ports }
        if !d.setup.isEmpty { obj["postCreateCommand"] = d.setup.joined(separator: " && ") }
        let data = (try? JSONSerialization.data(withJSONObject: obj,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return "// Generated by Titan from: \(d.evidence.joined(separator: ", "))\n"
            + "// Standard Dev Container format: also works with VS Code Dev Containers and Codespaces.\n"
            + String(decoding: data, as: UTF8.self) + "\n"
    }
}
