import Foundation

/// A language runtime served from Titan's shared toolchain store instead of baked into
/// the project image. Requested with standard Dev Container features, e.g.
/// `"features": {"ghcr.io/devcontainers/features/node:1": {"version": "22"}}`, so the same
/// devcontainer.json still works in VS Code Dev Containers and Codespaces.
///
/// Each exact build is copied once from its official slim image into a named volume,
/// precompiled where needed, and mounted read-only into every VM that uses it (several
/// VMs share one volume at native disk speed: measured equal to a baked-in runtime).
public struct ToolchainRequest: Codable, Equatable, Sendable {
    public var kind: Toolchain.Kind
    public var version: String
}

public enum Toolchain {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case node, python
    }

    public static let toolsRoot = "/opt/titan/tools"
    public static let venv = "/opt/titan/venv"
    /// npm global installs and corepack shims (a writable place; the store is read-only).
    public static func npmPrefix(home: String?) -> String { "\(home ?? "/root")/.npm-global" }
    /// buildpack-deps' own PATH, which toolchain directories are prepended to.
    public static let basePath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    /// The language-neutral base the official language images are themselves built on.
    public static let baseImage = "buildpack-deps:bookworm"

    public static func featureID(_ kind: Kind) -> String { "ghcr.io/devcontainers/features/\(kind.rawValue):1" }

    public static func defaultVersion(_ kind: Kind) -> String {
        switch kind {
        case .node: Catalog.node.defaultVersion
        case .python: Catalog.python.defaultVersion
        }
    }

    /// Official slim image the toolchain is copied from (pinned by digest in titan.lock).
    public static func sourceImage(_ r: ToolchainRequest) -> String {
        switch r.kind {
        case .node: "node:\(r.version)-bookworm-slim"
        case .python: "python:\(r.version)-slim-bookworm"
        }
    }

    public static func approxDownloadMB(_ kind: Kind) -> Int {
        switch kind { case .node: 76; case .python: 43 }
    }

    public static func guestPath(_ kind: Kind) -> String { "\(toolsRoot)/\(kind.rawValue)" }

    /// Content-addressed: one volume per exact build, shared by every project using it.
    public static func volumeName(_ r: ToolchainRequest, digest: String) -> String {
        let v = r.version.replacingOccurrences(of: ".", with: "-")
        return "titan-tool-\(r.kind.rawValue)-\(v)-\(digest.replacingOccurrences(of: "sha256:", with: "").prefix(12))"
    }

    /// Runs in the source image with the volume at /out. Python's .pyc files are compiled
    /// up front: the store is read-only, and without them imports were 3-4x slower.
    public static func fillScript(_ kind: Kind) -> String {
        switch kind {
        case .node:
            return "set -e; cp -a /usr/local/. /out/; touch /out/.titan-complete"
        case .python:
            return "set -e; cp -a /usr/local/. /out/; "
                + "LD_LIBRARY_PATH=/out/lib /out/bin/python3 -m compileall -q -j0 /out/lib/python3.* >/dev/null 2>&1 || true; "
                + "touch /out/.titan-complete"
        }
    }

    /// VM environment for a set of toolchains (writable places for what the read-only
    /// store can't hold: npm globals, a Python virtualenv).
    public static func environment(_ kinds: [Kind], home: String? = nil) -> [String: String] {
        guard !kinds.isEmpty else { return [:] }
        var path: [String] = []
        var env: [String: String] = [:]
        if kinds.contains(.node) {
            path += ["\(npmPrefix(home: home))/bin", "\(guestPath(.node))/bin"]
            env["NPM_CONFIG_PREFIX"] = npmPrefix(home: home)
        }
        if kinds.contains(.python) {
            path += ["\(venv)/bin", "\(guestPath(.python))/bin"]
            env["VIRTUAL_ENV"] = venv
            env["LD_LIBRARY_PATH"] = "\(guestPath(.python))/lib"
        }
        env["PATH"] = (path + [basePath]).joined(separator: ":")
        return env
    }

    /// One-time setup in a fresh VM, before generators and postCreate.
    /// Runs as root; hands the writable places to `user` when commands run as someone else.
    public static func setupSteps(_ kinds: [Kind], user: VMUser? = nil) -> [String] {
        var steps: [String] = []
        let prefix = npmPrefix(home: user?.home)
        if kinds.contains(.node) { steps.append("mkdir -p \(prefix)/bin && corepack enable --install-directory \(prefix)/bin") }
        if kinds.contains(.python) { steps.append("python3 -m venv \(venv)") }
        if let user, !steps.isEmpty {
            let owned = [kinds.contains(.node) ? prefix : nil, kinds.contains(.python) ? venv : nil].compactMap { $0 }
            steps.append("chown -R \(user.name): \(owned.joined(separator: " "))")
        }
        return steps
    }

    /// Maps devcontainer features to toolchains; unknown features are an error rather than
    /// silently giving an environment that differs from what the file promises.
    public static func requests(from features: [String: FeatureOptions]) throws -> [ToolchainRequest] {
        try features.keys.sorted().map { id in
            guard let kind = kind(forFeature: id) else {
                throw TitanError.message("Dev Container feature '\(id)' isn't supported by Titan yet "
                                         + "(supported: \(Kind.allCases.map { featureID($0) }.joined(separator: ", "))).")
            }
            let v = features[id]?.version
            let version = (v == nil || v == "latest" || v == "lts") ? defaultVersion(kind) : v!
            return ToolchainRequest(kind: kind, version: version)
        }
    }

    static func kind(forFeature id: String) -> Kind? {
        let base = id.split(separator: ":").first.map(String.init) ?? id
        for kind in Kind.allCases where base == "ghcr.io/devcontainers/features/\(kind.rawValue)" { return kind }
        return nil
    }
}

/// A feature's options object (or bare version string); only `version` matters to Titan.
public struct FeatureOptions: Decodable, Equatable, Sendable {
    public var version: String?

    public init(version: String?) { self.version = version }

    enum CodingKeys: String, CodingKey { case version }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { version = s; return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .version) { version = s }
        else if let n = try? c.decode(Double.self, forKey: .version) {
            version = n == n.rounded() ? String(Int(n)) : String(n)
        } else { version = nil }
    }
}
