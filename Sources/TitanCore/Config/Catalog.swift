import Foundation

/// Titan's curated defaults: which version of each runtime a new project gets and the
/// image that provides it. Updated with Titan releases so nobody hardcodes "latest".
public enum Catalog {
    public struct Runtime: Sendable, Equatable {
        public var id: String
        public var displayName: String
        /// Recommended version: current LTS / broadly supported stable.
        public var defaultVersion: String
        /// Rough compressed download size, for the plan screen (unpacked is ~3×).
        public var approxDownloadMB: Int
        let imageTemplate: String
        public func image(version: String? = nil) -> String {
            imageTemplate.replacingOccurrences(of: "{v}", with: version ?? defaultVersion)
        }
    }

    public static let node = Runtime(id: "node", displayName: "Node", defaultVersion: "22",
                                     approxDownloadMB: 390, imageTemplate: "node:{v}-bookworm")
    public static let python = Runtime(id: "python", displayName: "Python", defaultVersion: "3.12",
                                       approxDownloadMB: 360, imageTemplate: "python:{v}-bookworm")
    public static let go = Runtime(id: "go", displayName: "Go", defaultVersion: "1.23",
                                   approxDownloadMB: 290, imageTemplate: "golang:{v}-bookworm")
    public static let rust = Runtime(id: "rust", displayName: "Rust", defaultVersion: "1",
                                     approxDownloadMB: 510, imageTemplate: "rust:{v}-bookworm")

    /// Approximate download size of a service image, for the plan screen.
    public static func approxDownloadMB(service image: String) -> Int {
        switch ServicePreset.repository(of: image) {
        case "postgres": 160
        case "redis": 45
        default: 150
        }
    }
}

/// A starter for `titan new`: the runtime, how to generate the code (inside the VM), and
/// how the result is installed and run.
public struct ProjectTemplate: Sendable, Equatable {
    public var id: String
    public var summary: String
    public var runtime: Catalog.Runtime
    public var ports: [Int]
    public var shims: [String]
    /// Shell steps run (joined with &&, in one shell) from a scratch folder that must end up
    /// containing `{dir}/`, whose contents are copied into the project. Keep the shell in the
    /// scratch folder: use `(cd {dir} && …)` subshells.
    public var generate: [String]
    /// Becomes postCreateCommand (runs on every fresh VM, e.g. for teammates).
    public var install: String?
    /// What to type to start developing.
    public var devCommand: String

    public static let all: [ProjectTemplate] = [
        ProjectTemplate(id: "vite", summary: "Vite + React + TypeScript", runtime: Catalog.node, ports: [5173],
                        shims: ["node", "npm", "npx"],
                        generate: ["npm create --yes vite@latest {dir} -- --template react-ts </dev/null"],
                        install: "npm install", devCommand: "npm run dev"),
        ProjectTemplate(id: "next", summary: "Next.js (App Router, TypeScript)", runtime: Catalog.node, ports: [3000],
                        shims: ["node", "npm", "npx"],
                        generate: ["npx --yes create-next-app@latest {dir} --ts --eslint --app --src-dir --tailwind --use-npm --yes --skip-install --disable-git </dev/null"],
                        install: "npm install", devCommand: "npm run dev"),
        ProjectTemplate(id: "node", summary: "Plain Node.js", runtime: Catalog.node, ports: [3000],
                        shims: ["node", "npm", "npx"],
                        generate: ["mkdir {dir} && (cd {dir} && npm init -y >/dev/null && npm pkg set name={name} scripts.dev='node --watch index.js')",
                                   #"printf '%s\n' "const http = require('node:http');" "http.createServer((req, res) => res.end('hello from {name}\\n')).listen(3000, () => console.log('http://localhost:3000'));" > {dir}/index.js"#],
                        install: "npm install", devCommand: "npm run dev"),
        ProjectTemplate(id: "fastapi", summary: "FastAPI", runtime: Catalog.python, ports: [8000],
                        shims: ["python", "python3", "pip", "pip3", "fastapi"],
                        generate: ["mkdir {dir} && echo 'fastapi[standard]' > {dir}/requirements.txt",
                                   #"printf '%s\n' 'from fastapi import FastAPI' '' 'app = FastAPI()' '' '' '@app.get("/")' 'def root():' '    return {"hello": "{name}"}' > {dir}/main.py"#],
                        install: "pip install -r requirements.txt", devCommand: "fastapi dev main.py"),
        ProjectTemplate(id: "django", summary: "Django", runtime: Catalog.python, ports: [8000],
                        shims: ["python", "python3", "pip", "pip3", "django-admin"],
                        generate: ["pip install --quiet django", "mkdir {dir} && django-admin startproject config {dir}",
                                   "echo django > {dir}/requirements.txt"],
                        install: "pip install -r requirements.txt", devCommand: "python manage.py runserver"),
        ProjectTemplate(id: "flask", summary: "Flask", runtime: Catalog.python, ports: [5000],
                        shims: ["python", "python3", "pip", "pip3", "flask"],
                        generate: ["mkdir {dir} && echo flask > {dir}/requirements.txt",
                                   #"printf '%s\n' 'from flask import Flask' '' 'app = Flask(__name__)' '' '' '@app.get("/")' 'def root():' '    return {"hello": "{name}"}' > {dir}/app.py"#],
                        install: "pip install -r requirements.txt", devCommand: "flask run"),
        ProjectTemplate(id: "python", summary: "Plain Python", runtime: Catalog.python, ports: [8000],
                        shims: ["python", "python3", "pip", "pip3"],
                        generate: ["mkdir {dir} && touch {dir}/requirements.txt && echo 'print(\"hello from {name}\")' > {dir}/main.py"],
                        install: "pip install -r requirements.txt", devCommand: "python main.py"),
        ProjectTemplate(id: "go", summary: "Go HTTP server", runtime: Catalog.go, ports: [8080],
                        shims: ["go", "gofmt"],
                        generate: ["mkdir {dir} && (cd {dir} && go mod init {name} 2>/dev/null)",
                                   #"printf '%s\n' 'package main' '' 'import (' '\#t"fmt"' '\#t"net/http"' ')' '' 'func main() {' '\#thttp.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, "hello from {name}") })' '\#tfmt.Println("http://localhost:8080")' '\#thttp.ListenAndServe(":8080", nil)' '}' > {dir}/main.go"#],
                        install: "go mod download", devCommand: "go run ."),
        ProjectTemplate(id: "rust", summary: "Rust (cargo)", runtime: Catalog.rust, ports: [],
                        shims: ["cargo", "rustc", "rustup"],
                        generate: ["cargo new --vcs none --name {dir} {dir}"],
                        install: "cargo fetch", devCommand: "cargo run"),
    ]

    public static func find(_ id: String) -> ProjectTemplate? { all.first { $0.id == id.lowercased() } }

    /// Runtimes the shared toolchain store can serve (others use their full image).
    public var toolchainKind: Toolchain.Kind? { Toolchain.Kind(rawValue: runtime.id) }

    /// Generator steps with the project name filled in.
    /// `{name}` is the project name; `{dir}` the scratch folder, its lowercased form, which
    /// generators use as the package name (npm requires lowercase).
    public func generateSteps(name: String) -> [String] {
        generate.map { $0.replacingOccurrences(of: "{name}", with: name).replacingOccurrences(of: "{dir}", with: Self.scratchDirectory(for: name)) }
    }

    public static func scratchDirectory(for name: String) -> String { name.lowercased() }
}

/// What `titan new` is about to do; shown before anything is downloaded.
public struct NewProjectPlan: Sendable {
    public struct Item: Sendable, Equatable {
        public var role: String
        public var label: String
        public var image: String
        public var approxDownloadMB: Int
        public var cached: Bool
    }

    public var name: String
    public var folder: URL
    public var template: ProjectTemplate
    public var runtimeVersion: String
    public var services: [ResolvedService]
    public var items: [Item]
    /// Runtime from the shared toolchain store on the common base (nil: full runtime image).
    public var toolchain: ToolchainRequest?

    public var image: String { toolchain == nil ? template.runtime.image(version: runtimeVersion) : Toolchain.baseImage }
    /// Download plus unpacked copy (~3× compressed), for the disk check.
    public var neededBytes: UInt64 {
        UInt64(items.filter { !$0.cached }.reduce(0) { $0 + $1.approxDownloadMB } * 4) << 20
    }

    /// Valid folder/package name: letters, digits, dashes, underscores; starts with a letter.
    public static func validate(name: String) throws {
        guard name.wholeMatch(of: /[A-Za-z][A-Za-z0-9_-]{0,63}/) != nil else {
            throw TitanError.message("'\(name)' isn't a good project name: use letters, digits, - and _, starting with a letter.")
        }
    }

    public static func make(name: String, folder: URL, template: ProjectTemplate, runtimeVersion: String?,
                            services: [String], localImages: [LocalImage], localVolumes: [String] = [],
                            useToolchainStore: Bool = true) throws -> NewProjectPlan {
        let version = runtimeVersion ?? template.runtime.defaultVersion
        let resolved = try services.map { try ResolvedService.resolve(name: ServicePreset.defaultName(for: $0), config: ServiceConfig(image: $0)) }
        let have = Set(localImages.flatMap(\.references).map(GarbageCollector.normalize))
        func cached(_ image: String) -> Bool { have.contains(GarbageCollector.normalize(image)) }
        var items: [Item]
        var toolchain: ToolchainRequest?
        if useToolchainStore, let kind = template.toolchainKind {
            let req = ToolchainRequest(kind: kind, version: version)
            toolchain = req
            let prefix = Toolchain.volumeName(req, digest: "")  // "titan-tool-node-22-" (any build of that version)
            items = [
                Item(role: "base", label: "Debian + tools", image: Toolchain.baseImage, approxDownloadMB: 324,
                     cached: cached(Toolchain.baseImage)),
                Item(role: "runtime", label: "\(template.runtime.displayName) \(version)", image: "shared toolchain store",
                     approxDownloadMB: Toolchain.approxDownloadMB(kind), cached: localVolumes.contains { $0.hasPrefix(prefix) }),
            ]
        } else {
            let image = template.runtime.image(version: version)
            items = [Item(role: "runtime", label: "\(template.runtime.displayName) \(version)", image: image,
                          approxDownloadMB: template.runtime.approxDownloadMB, cached: cached(image))]
        }
        for s in resolved {
            items.append(Item(role: "service", label: s.name, image: s.image,
                              approxDownloadMB: Catalog.approxDownloadMB(service: s.image), cached: cached(s.image)))
        }
        return NewProjectPlan(name: name, folder: folder, template: template, runtimeVersion: version,
                              services: resolved, items: items, toolchain: toolchain)
    }

    /// devcontainer.json for the new project (standard format, Titan bits under customizations).
    public func devcontainer() -> String {
        var titan: [String: Any] = ["shims": template.shims]
        if !services.isEmpty { titan["services"] = services.map(\.image) }
        var obj: [String: Any] = ["name": name, "image": image, "customizations": ["titan": titan]]
        if let t = toolchain { obj["features"] = [Toolchain.featureID(t.kind): ["version": t.version]] }
        if !template.ports.isEmpty { obj["forwardPorts"] = template.ports }
        if let install = template.install { obj["postCreateCommand"] = install }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return "// Created by `titan new --\(template.id)`. Standard Dev Container format.\n"
            + String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The scratch-folder generation script run in the VM, ending with a copy into the project.
    public func generationScript(workspace: String) -> String {
        let steps = template.generateSteps(name: name).joined(separator: " && ")
        return "set -e; rm -rf /tmp/titan-new && mkdir -p /tmp/titan-new && cd /tmp/titan-new && \(steps) && "
            // cp -R, not -a: the workspace root is a host mount whose timestamps can't be set.
            + "cp -R /tmp/titan-new/\(ProjectTemplate.scratchDirectory(for: name))/. \(shellQuote(workspace))/ && rm -rf /tmp/titan-new"
    }
}
