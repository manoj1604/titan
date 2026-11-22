import Foundation

/// What zero-config detection inferred about a project.
public struct DetectedStack: Equatable, Sendable {
    public var kind: String
    public var image: String
    public var ports: [Int]
    public var setup: [String]
    public var shims: [String]
    public var evidence: [String]
}

/// Infers a dev environment from the files already in a repo, so `titan up`
/// works in projects that have never heard of Titan.
public enum StackDetector {
    /// Files that mark the root of a project in a language Titan knows.
    public static let manifests = [
        "package.json", "pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "go.mod",
        "Cargo.toml", "Gemfile", "pom.xml", "build.gradle", "build.gradle.kts",
    ]

    public static func detect(at root: URL) -> DetectedStack {
        let probe = Probe(root: root)
        return node(probe) ?? python(probe) ?? go(probe) ?? rust(probe) ?? ruby(probe) ?? java(probe)
            ?? DetectedStack(kind: "generic", image: "debian:bookworm", ports: [], setup: [], shims: [],
                             evidence: ["no known manifest found"])
    }

    /// Stacks `titan create <name>` offers for a folder without a manifest yet.
    public static let presetNames = ["node", "python", "go", "rust", "ruby", "java"]

    /// `node`, `python@3.13`, `go@1.23`… → the stack's image, shims and usual port (no setup
    /// commands: there's nothing to install yet). nil for an unknown name.
    public static func preset(_ spec: String) -> DetectedStack? {
        let parts = spec.lowercased().split(separator: "@", maxSplits: 1).map(String.init)
        let name = parts[0], v = parts.count > 1 ? parts[1] : nil
        let why = ["titan create \(spec)"]
        switch name {
        case "node", "nodejs", "javascript", "typescript":
            return DetectedStack(kind: "node", image: "node:\(v ?? "22")-bookworm", ports: [3000, 5173], setup: [],
                                 shims: ["node", "npm", "npx"], evidence: why)
        case "python", "py":
            return DetectedStack(kind: "python", image: "python:\(v ?? "3.12")-bookworm", ports: [8000], setup: [],
                                 shims: ["python", "python3", "pip", "pip3"], evidence: why)
        case "go", "golang":
            return DetectedStack(kind: "go", image: "golang:\(v ?? "1")-bookworm", ports: [8080], setup: [],
                                 shims: ["go", "gofmt"], evidence: why)
        case "rust":
            return DetectedStack(kind: "rust", image: "rust:\(v ?? "1")-bookworm", ports: [8080], setup: [],
                                 shims: ["cargo", "rustc", "rustup"], evidence: why)
        case "ruby":
            return DetectedStack(kind: "ruby", image: "ruby:\(v ?? "3.3")-bookworm", ports: [3000], setup: [],
                                 shims: ["ruby", "gem", "bundle", "rake", "rails"], evidence: why)
        case "java":
            return DetectedStack(kind: "java", image: "eclipse-temurin:\(v ?? "21")", ports: [8080], setup: [],
                                 shims: ["java", "javac"], evidence: why)
        default:
            return nil
        }
    }

    // MARK: Stacks

    static func node(_ p: Probe) -> DetectedStack? {
        guard p.exists("package.json") else { return nil }
        var evidence = ["package.json"]
        var major = "22"
        if let nvmrc = p.read(".nvmrc") ?? p.read(".node-version"), let v = version(in: nvmrc, parts: 1) {
            major = v; evidence.append(p.exists(".nvmrc") ? ".nvmrc" : ".node-version")
        } else if let engines = p.json("package.json")?["engines"] as? [String: Any],
                  let spec = engines["node"] as? String, let v = version(in: spec, parts: 1) {
            major = v; evidence.append("engines.node")
        }
        var shims = ["node", "npm", "npx"]
        let setup: String
        if p.exists("pnpm-lock.yaml") {
            setup = "corepack enable && pnpm install --frozen-lockfile"; shims += ["pnpm"]; evidence.append("pnpm-lock.yaml")
        } else if p.exists("yarn.lock") {
            setup = "corepack enable && yarn install"; shims += ["yarn"]; evidence.append("yarn.lock")
        } else if p.exists("bun.lockb") || p.exists("bun.lock") {
            setup = "npm install -g bun && bun install"; shims += ["bun"]; evidence.append("bun.lock")
        } else if p.exists("package-lock.json") {
            setup = "npm ci"; evidence.append("package-lock.json")
        } else {
            setup = "npm install"
        }
        return DetectedStack(kind: "node", image: "node:\(major)-bookworm", ports: nodePorts(p), setup: [setup],
                             shims: shims, evidence: evidence)
    }

    static func python(_ p: Probe) -> DetectedStack? {
        let manifests = ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "uv.lock"]
        let found = manifests.filter(p.exists)
        guard !found.isEmpty else { return nil }
        var evidence = found
        var ver = "3.12"
        if let pv = p.read(".python-version"), let v = version(in: pv, parts: 2) {
            ver = v; evidence.append(".python-version")
        } else if let py = p.read("pyproject.toml"),
                  let line = py.split(separator: "\n").first(where: { $0.contains("requires-python") }),
                  let v = version(in: String(line), parts: 2), v.contains(".") {
            ver = v; evidence.append("requires-python")
        }
        var shims = ["python", "python3", "pip", "pip3"]
        var setup: [String] = []
        if p.exists("uv.lock") {
            setup = ["pip install --quiet uv && uv sync"]; shims += ["uv"]
        } else if p.exists("requirements.txt") {
            setup = ["pip install -r requirements.txt"]
        } else if p.exists("Pipfile") {
            setup = ["pip install --quiet pipenv && pipenv install --system --dev"]
        } else if p.exists("pyproject.toml") || p.exists("setup.py") {
            setup = ["pip install -e ."]
        }
        return DetectedStack(kind: "python", image: "python:\(ver)-bookworm", ports: pythonPorts(p), setup: setup,
                             shims: shims, evidence: evidence)
    }

    static func go(_ p: Probe) -> DetectedStack? {
        guard let mod = p.read("go.mod") else { return nil }
        var ver = "1"
        if let line = mod.split(separator: "\n").first(where: { $0.hasPrefix("go ") }),
           let v = version(in: String(line), parts: 2) { ver = v }
        return DetectedStack(kind: "go", image: "golang:\(ver)-bookworm", ports: [8080], setup: ["go mod download"],
                             shims: ["go", "gofmt"], evidence: ["go.mod"])
    }

    static func rust(_ p: Probe) -> DetectedStack? {
        guard p.exists("Cargo.toml") else { return nil }
        return DetectedStack(kind: "rust", image: "rust:1-bookworm", ports: [8080], setup: ["cargo fetch"],
                             shims: ["cargo", "rustc", "rustup"], evidence: ["Cargo.toml"])
    }

    static func ruby(_ p: Probe) -> DetectedStack? {
        guard p.exists("Gemfile") else { return nil }
        var evidence = ["Gemfile"]
        var ver = "3.3"
        if let rv = p.read(".ruby-version"), let v = version(in: rv, parts: 2) { ver = v; evidence.append(".ruby-version") }
        return DetectedStack(kind: "ruby", image: "ruby:\(ver)-bookworm", ports: [3000], setup: ["bundle install"],
                             shims: ["ruby", "bundle", "rake", "rails"], evidence: evidence)
    }

    static func java(_ p: Probe) -> DetectedStack? {
        if p.exists("pom.xml") {
            return DetectedStack(kind: "java-maven", image: "maven:3-eclipse-temurin-21", ports: [8080],
                                 setup: ["mvn -q dependency:go-offline"], shims: ["mvn", "java"], evidence: ["pom.xml"])
        }
        if p.exists("build.gradle") || p.exists("build.gradle.kts") {
            return DetectedStack(kind: "java-gradle", image: "gradle:jdk21", ports: [8080], setup: [],
                                 shims: ["gradle", "java"], evidence: ["build.gradle"])
        }
        return nil
    }

    // MARK: Ports

    /// Dev-server ports by framework, so `npm run dev` is reachable without config.
    static func nodePorts(_ p: Probe) -> [Int] {
        let pkg = p.json("package.json") ?? [:]
        let deps = ((pkg["dependencies"] as? [String: Any]) ?? [:]).merging((pkg["devDependencies"] as? [String: Any]) ?? [:]) { a, _ in a }
        var ports: [Int] = []
        if deps["@angular/core"] != nil { ports.append(4200) }
        if deps["astro"] != nil { ports.append(4321) }
        if deps["vite"] != nil || deps["@sveltejs/kit"] != nil { ports.append(5173) }
        if deps["next"] != nil || deps["nuxt"] != nil || deps["express"] != nil || deps["@remix-run/dev"] != nil || ports.isEmpty {
            ports.append(3000)
        }
        return ports
    }

    /// Django/FastAPI/uvicorn use 8000; Flask's default is 5000.
    static func pythonPorts(_ p: Probe) -> [Int] {
        let text = ["requirements.txt", "pyproject.toml", "Pipfile", "setup.py"].compactMap(p.read).joined(separator: "\n").lowercased()
        let usesFlask = text.range(of: #"(^|[^a-z0-9_-])flask([^a-z0-9_-]|$)"#, options: .regularExpression) != nil
        return usesFlask ? [8000, 5000] : [8000]
    }

    // MARK: Helpers

    /// First version number in `text`, truncated to `parts` components ("v20.11.1" -> "20" or "20.11").
    static func version(in text: String, parts: Int) -> String? {
        guard let m = text.firstMatch(of: /(\d+)(?:\.(\d+))?/) else { return nil }
        if parts >= 2, let minor = m.2 { return "\(m.1).\(minor)" }
        return String(m.1)
    }

    struct Probe {
        let root: URL
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }
        func read(_ name: String) -> String? { try? String(contentsOf: url(name), encoding: .utf8) }
        func json(_ name: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: url(name)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
}
