import Foundation
import Testing
@testable import TitanCore

/// Runs the real zsh/bash hook against a fake `titan` that logs its calls and, on
/// `activate`, writes a shim the way the real one does.
@Suite struct HookTests {
    struct Sandbox {
        let root: URL
        let fakeTitan: URL
        let log: URL

        init(failActivate: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("hook-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            log = root.appendingPathComponent("calls.log")
            fakeTitan = root.appendingPathComponent("fake-titan")
            let body = failActivate ? "exit 1" : #"mkdir -p "$3/.titan/bin" && touch "$3/.titan/bin/node""#
            try Data("""
            #!/bin/sh
            echo "$@" >> '\(log.path)'
            \(body)
            """.utf8).write(to: fakeTitan)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTitan.path)
        }

        func file(_ rel: String, _ text: String = "{}") throws {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        var calls: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        /// Runs `steps` after loading the hook; returns stdout + stderr.
        func run(_ shell: String, _ steps: String) throws -> String {
            let hook = ShellHook.script(for: shell, titan: fakeTitan.path)!
            let hookFile = root.appendingPathComponent("hook.\(shell)")
            try Data(hook.utf8).write(to: hookFile)
            // bash fires the hook from PROMPT_COMMAND, which a script never shows; call it after each cd.
            let cd = shell == "bash" ? "tcd() { cd \"$1\" && _titan_hook; }" : "tcd() { cd \"$1\"; }"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/\(shell)")
            p.arguments = ["-c", "export HOME='\(root.path)'; cd '\(root.path)'; \(cd); source '\(hookFile.path)'; \(steps)"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
    }

    @Test(arguments: ["zsh", "bash"])
    func freshCloneIsActivatedOnceAndRoutedOnPath(shell: String) throws {
        let s = try Sandbox()
        try s.file("app/.devcontainer.json")
        try s.file("app/src/x.js", "")
        let out = try s.run(shell, """
        tcd app; echo "PATH1=${PATH%%:*}"
        tcd src; echo "PATH2=${PATH%%:*}"
        tcd ..; tcd ..; echo "PATH3=${PATH%%:*}"
        """)
        let app = s.root.appendingPathComponent("app").path
        #expect(out.contains("PATH1=\(app)/.titan/bin"))
        #expect(out.contains("PATH2=\(app)/.titan/bin"))      // subdirectories stay routed
        #expect(!out.contains("PATH3=\(app)"))                 // leaving restores PATH
        #expect(s.calls == ["activate -C \(app)"])            // spawned titan exactly once
    }

    @Test(arguments: ["zsh", "bash"])
    func configChangeReactivates(shell: String) throws {
        let s = try Sandbox()
        try s.file("app/titan.lock")
        _ = try s.run(shell, "tcd app")
        // Make the lockfile newer than the shims, as a `git pull` that changed it would.
        let lock = s.root.appendingPathComponent("app/titan.lock").path
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: lock)
        _ = try s.run(shell, "tcd app")
        #expect(s.calls.count == 2)
    }

    @Test(arguments: ["zsh", "bash"])
    func plainReposGetAOneTimeHintAndNoRouting(shell: String) throws {
        let s = try Sandbox()
        try s.file("plain/package.json")
        let out = try s.run(shell, "tcd plain; tcd ..; tcd plain; echo \"PATH=${PATH%%:*}\"")
        #expect(out.components(separatedBy: "titan up").count - 1 == 1)
        #expect(s.calls.isEmpty)
        #expect(!out.contains("PATH=\(s.root.path)/plain/.titan/bin"))
    }

    @Test(arguments: ["zsh", "bash"])
    func failedActivationLeavesCommandsOnTheMac(shell: String) throws {
        let s = try Sandbox(failActivate: true)
        try s.file("app/.devcontainer.json", "{ broken")
        let out = try s.run(shell, "tcd app; echo \"ROOT=${TITAN_PROJECT_ROOT:-none}\"")
        #expect(out.contains("ROOT=none"))
    }

    @Test(arguments: ["zsh", "bash"])
    func quietModePrintsNothing(shell: String) throws {
        let s = try Sandbox()
        try s.file("app/.titan/bin/node", "")
        try s.file("plain/package.json")
        let out = try s.run(shell, "export TITAN_QUIET=1; tcd app; tcd ../plain")
        #expect(out.isEmpty)
    }
}

@Suite struct ActivationTests {
    @Test func activateWritesShimsWithoutTouchingTheVM() throws {
        let t = try TempProject([".devcontainer.json": #"{"image":"node:22","customizations":{"titan":{"shims":["node","npm"]}}}"#])
        let rt = FakeRuntime()
        let cmds = try makeEngine(t.project, rt).activate()
        #expect(cmds == ["node", "npm"])
        #expect(FileManager.default.isExecutableFile(atPath: t.project.shimDir.appendingPathComponent("npm").path))
        #expect(rt.calls.isEmpty && rt.runs.isEmpty)
    }

    @Test func firstShimRunSetsUpTheVM() throws {
        let t = try TempProject(["package.json": "{}"])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        #expect(throws: ReplacedProcess.self) { try engine.run(["npm", "test"], cwd: t.project.root.path, announce: Console(quiet: true)) }
        #expect(rt.runs.count == 1)
    }
}

@Suite struct PortDetectionTests {
    func ports(_ files: [String: String]) throws -> [Int] {
        let t = try TempProject(files)  // keep alive: it deletes its folder when released
        return StackDetector.detect(at: t.url).ports
    }

    @Test func nodeFrameworks() throws {
        #expect(try ports(["package.json": #"{"devDependencies":{"vite":"^5"}}"#]) == [5173])
        #expect(try ports(["package.json": #"{"dependencies":{"next":"15"}}"#]) == [3000])
        #expect(try ports(["package.json": #"{"dependencies":{"@angular/core":"18"}}"#]) == [4200])
        #expect(try ports(["package.json": #"{"dependencies":{"astro":"4"}}"#]) == [4321])
        #expect(try ports(["package.json": #"{"dependencies":{"express":"4"},"devDependencies":{"vite":"5"}}"#]) == [5173, 3000])
        #expect(try ports(["package.json": "{}"]) == [3000])
    }

    @Test func pythonFrameworks() throws {
        #expect(try ports(["requirements.txt": "flask==3.1.0\n"]) == [8000, 5000])
        #expect(try ports(["requirements.txt": "Flask>=3\n"]) == [8000, 5000])
        #expect(try ports(["requirements.txt": "django\nflask-cors-helper-x\n"]) == [8000])
        #expect(try ports(["pyproject.toml": "dependencies = [\"fastapi\"]\n"]) == [8000])
    }
}
