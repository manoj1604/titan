import Foundation
import Testing
@testable import TitanCore

@Suite struct EngineTests {
    @Test func upCreatesVMRunsPostCreateAndWritesLockAndShims() throws {
        let t = try TempProject(["package.json": "{}", "package-lock.json": "{}"])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        try engine.up()

        let name = t.project.containerName
        #expect(rt.calls == ["pull node:22-bookworm", "run \(name)"])
        #expect(rt.runs.first?.ports == [.same(3000)])
        #expect(rt.runs.first?.hostPath == t.project.root.path)
        #expect(rt.execs.map(\.command) == [["/bin/sh", "-c", "npm ci"]])
        #expect(Lockfile.load(t.project) == Lockfile(image: "node:22-bookworm", digest: "sha256:abc123"))
        #expect(FileManager.default.isExecutableFile(atPath: t.project.shimDir.appendingPathComponent("npm").path))
        #expect(FileManager.default.fileExists(atPath: t.project.stateDir.appendingPathComponent(".gitignore").path))
    }

    @Test func secondUpIsANoOp() throws {
        let t = try TempProject(["go.mod": "go 1.22\n"])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt).up()
        rt.calls.removeAll(); rt.execs.removeAll()
        try makeEngine(t.project, rt).up()
        #expect(rt.calls.isEmpty)
        #expect(rt.execs.isEmpty)
    }

    @Test func lockfilePinsDigestOnFreshMachine() throws {
        let t = try TempProject(["go.mod": "go 1.22\n"])
        try Lockfile(image: "golang:1.22-bookworm", digest: "sha256:pinned").save(t.project)
        let rt = FakeRuntime()
        try makeEngine(t.project, rt).up()
        #expect(rt.calls.first == "pull golang:1.22-bookworm@sha256:pinned")
        #expect(rt.runs.first?.image == "golang:1.22-bookworm@sha256:pinned")
    }

    @Test func failedPostCreateResumesOnNextUp() throws {
        let t = try TempProject(["go.mod": "go 1.22\n"])
        let rt = FakeRuntime()
        rt.execExitCode = 1
        #expect(throws: TitanError.lifecycleFailed("postCreate", 1)) { try makeEngine(t.project, rt).up() }
        rt.execExitCode = 0
        rt.execs.removeAll()
        try makeEngine(t.project, rt).up()
        #expect(rt.execs.map(\.command) == [["/bin/sh", "-c", "go mod download"]])
    }

    @Test func configChangeRecreatesStoppedVM() throws {
        let t = try TempProject([".devcontainer.json": #"{"image": "a:1"}"#])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt).up()
        let name = t.project.containerName
        rt.containers[name] = .stopped
        try t.write(".devcontainer.json", #"{"image": "a:2"}"#)
        rt.calls.removeAll()
        try makeEngine(t.project, rt).up()
        #expect(rt.calls == ["remove \(name)", "pull a:2", "run \(name)"])
    }

    @Test func runMapsCwdAndArgsIntoGuest() throws {
        let t = try TempProject(["package.json": "{}", "src/x.js": ""])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt, tty: true)
        try engine.up()
        let src = t.project.root.path + "/src"
        do {
            try engine.run(["node", src + "/x.js"], cwd: src)
        } catch let r as ReplacedProcess {
            let ws = "/workspaces/\(t.project.name)"
            #expect(r.spec.workdir == ws + "/src")
            #expect(r.spec.command == ["node", ws + "/src/x.js"])
            #expect(r.spec.tty)
            #expect(r.spec.interactive)
        }
    }

    @Test func runAutoStartsVM() throws {
        let t = try TempProject(["go.mod": "go 1.22\n"])
        let rt = FakeRuntime()
        #expect(throws: ReplacedProcess.self) { try makeEngine(t.project, rt).run(["go", "version"], cwd: t.project.root.path) }
        #expect(rt.calls.contains("run \(t.project.containerName)"))
    }

    @Test func missingRuntimeIsReported() throws {
        let t = try TempProject()
        let rt = FakeRuntime()
        rt.installed = false
        #expect(throws: TitanError.runtimeMissing) { try makeEngine(t.project, rt).up() }
    }

    @Test func startsSystemServiceWhenNeeded() throws {
        let t = try TempProject()
        let rt = FakeRuntime()
        rt.systemRunning = false
        try makeEngine(t.project, rt).up()
        #expect(rt.calls.first == "system start")
    }
}

@Suite struct AppleRuntimeTests {
    let rt = AppleContainerRuntime(runner: ProcessRunner())

    @Test func runArguments() {
        let spec = RunSpec(name: "titan-x-1", image: "node:22", hostPath: "/Users/me/x", guestPath: "/workspaces/x",
                           ports: [.same(3000), PortMapping(host: 3001, guest: 8080)], env: ["B": "2", "A": "1"], cpus: 2, memory: "4G")
        let args = rt.runArguments(spec)
        #expect(Array(args.prefix(10)) == ["container", "run", "--detach", "--name", "titan-x-1",
                                           "--volume", "/Users/me/x:/workspaces/x", "--workdir", "/workspaces/x", "--publish"])
        #expect(args.contains("127.0.0.1:3000:3000"))
        #expect(args.contains("127.0.0.1:3001:8080"))
        #expect(args.firstIndex(of: "A=1")! < args.firstIndex(of: "B=2")!)
        #expect(args.contains("node:22"))
    }

    @Test func execArguments() {
        let spec = ExecSpec(name: "c", command: ["npm", "test"], workdir: "/w", env: ["TERM": "xterm"],
                            interactive: true, tty: false)
        #expect(rt.execArguments(spec) == ["container", "exec", "--interactive", "--workdir", "/w",
                                           "--env", "TERM=xterm", "c", "npm", "test"])
    }

    @Test func parsesInspectStatus() {
        // Real shape from container 1.7.1.
        #expect(AppleContainerRuntime.parseStatus(#"[{"configuration":{"id":"x","networks":[]},"id":"x","status":{"networks":[],"state":"running"}}]"#) == .running)
        #expect(AppleContainerRuntime.parseStatus(#"[{"configuration":{},"status":{"networks":[],"state":"stopped"}}]"#) == .stopped)
        // Older string form.
        #expect(AppleContainerRuntime.parseStatus(#"[{"status":"running","configuration":{}}]"#) == .running)
        #expect(AppleContainerRuntime.parseStatus(#"[{"status":"stopped"}]"#) == .stopped)
        #expect(AppleContainerRuntime.parseStatus("[]") == .missing)
        #expect(AppleContainerRuntime.parseStatus("not json") == .missing)
    }
}

@Suite struct IntegrationFileTests {
    @Test func shimScriptQuotesPaths() throws {
        let p = Project(root: URL(fileURLWithPath: "/tmp/it's here"))
        let s = ShimWriter.script(command: "npm", project: p, titan: "/opt/titan")
        #expect(s.contains("exec /opt/titan run -C \(shellQuote(p.root.path)) --shim -- npm \"$@\""))
        #expect(shellQuote(p.root.path).hasSuffix("it'\\''s here'"))
    }

    @Test func vscodeMergesExistingSettings() throws {
        let t = try TempProject([".vscode/settings.json": #"{"editor.tabSize": 2}"#])
        let outcome = try VSCodeIntegration.install(project: t.project, titan: "/opt/titan")
        guard case .written(let url) = outcome else { Issue.record("expected write"); return }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(obj["editor.tabSize"] as? Int == 2)
        #expect(obj["terminal.integrated.defaultProfile.osx"] as? String == "Titan VM")
    }

    @Test func vscodeRefusesToClobberComments() throws {
        let t = try TempProject([".vscode/settings.json": "{\n // keep me\n \"a\": 1\n}"])
        guard case .manual = try VSCodeIntegration.install(project: t.project, titan: "/opt/titan") else {
            Issue.record("expected manual"); return
        }
    }
}

@Suite struct PersistenceTests {
    @Test func dryRunWritesNothing() throws {
        let t = try TempProject(["go.mod": "go 1.22\n"])
        let paths = tempPaths()
        let engine = Engine(project: t.project, runtime: FakeRuntime(), console: Console(quiet: true),
                            terminal: TerminalInfo(stdinIsTTY: false, stdoutIsTTY: false),
                            titanExecutable: "/x", persist: false, paths: paths)
        try engine.up()
        #expect(!FileManager.default.fileExists(atPath: paths.registryURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.sharedCache.path))
        #expect(!FileManager.default.fileExists(atPath: t.project.stateDir.path))
        #expect(!FileManager.default.fileExists(atPath: t.project.lockfileURL.path))
    }

    @Test func noLockWithoutDigest() throws {
        let t = try TempProject(["go.mod": "go 1.22\n"])
        let rt = FakeRuntime()
        rt.digest = nil
        try makeEngine(t.project, rt).up()
        #expect(Lockfile.load(t.project) == nil)
    }

    @Test func tmpPathsCanonicalizeToPrivate() {
        #expect(Project(root: URL(fileURLWithPath: "/tmp")).root.path == "/private/tmp")
    }
}
