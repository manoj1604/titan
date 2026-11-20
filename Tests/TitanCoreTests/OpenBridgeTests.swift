import Foundation
import Testing
@testable import TitanCore

@Suite struct OpenBridgeTests {
    func bridge() throws -> (OpenBridge, TempProject) {
        let t = try TempProject(["src/App.tsx": "x"])
        return (OpenBridge(project: t.project, workspace: "/workspaces/shop", token: "T0K"), t)
    }

    @Test func helperWritesARequestWithAbsolutePaths() throws {
        let (b, t) = try bridge()
        try b.install()
        let helper = b.helperDir.appendingPathComponent("code").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "cd '\(t.url.path)' && TITAN_OPEN_DIR='\(b.mailbox.path)' TITAN_OPEN_TOKEN=T0K '\(helper)' -g src/App.tsx:12 /workspaces/shop/README.md"]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: b.mailbox.path).filter { $0.hasPrefix("req.") }
        #expect(files.count == 1)
        let text = try String(contentsOf: b.mailbox.appendingPathComponent(files[0]), encoding: .utf8)
        #expect(text == "T0K\ncode\n-g\n\(t.url.path)/src/App.tsx:12\n/workspaces/shop/README.md\n")
    }

    @Test func helperOutsideAShellExplainsItself() throws {
        let (b, _) = try bridge()
        try b.install()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: b.helperDir.appendingPathComponent("cursor").path)
        p.arguments = ["x"]
        p.environment = ["PATH": "/usr/bin:/bin"]
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 1)
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("only works inside `titan shell`"))
    }

    @Test func mapsVMPathsToTheMacAndRefusesEverythingElse() throws {
        let (b, t) = try bridge()
        let req = OpenBridge.Request(command: "code", arguments: ["-g", "/workspaces/shop/src/App.tsx:12", "/etc/hosts", "/workspaces/shop/../../etc/passwd"])
        let plan = b.plan(req, which: { $0 == "code" ? "/usr/local/bin/code" : nil })
        #expect(plan.commands == [["/usr/local/bin/code", "-g", "\(t.project.root.path)/src/App.tsx:12"]])
        #expect(plan.warnings.count == 2)
    }

    @Test func fallsBackToTheAppWhenTheEditorCommandIsMissing() throws {
        let (b, t) = try bridge()
        let plan = b.plan(.init(command: "cursor", arguments: ["/workspaces/shop/src"]), which: { _ in nil })
        #expect(plan.commands == [["/usr/bin/open", "-a", "Cursor", "\(t.project.root.path)/src"]])
    }

    @Test func bareEditorOpensTheProjectAndOpenHandlesURLs() throws {
        let (b, t) = try bridge()
        #expect(b.plan(.init(command: "code", arguments: []), which: { _ in "/x/code" }).commands == [["/x/code", t.project.root.path]])
        let open = b.plan(.init(command: "xdg-open", arguments: ["http://localhost:5173", "/workspaces/shop/README.md"]), which: { _ in nil })
        #expect(open.commands == [["/usr/bin/open", "http://localhost:5173"], ["/usr/bin/open", "\(t.project.root.path)/README.md"]])
    }

    @Test func requestsFromOtherSessionsOrUnknownCommandsAreIgnored() throws {
        let (b, _) = try bridge()
        #expect(b.parse("WRONG\ncode\n/workspaces/shop") == nil)
        #expect(b.parse("T0K\nrm\n-rf") == nil)
        #expect(b.parse("T0K\ncode\n/workspaces/shop/a\n") == .init(command: "code", arguments: ["/workspaces/shop/a"]))
    }

    @Test func drainRunsEachRequestOnceAndDeletesIt() throws {
        let (b, _) = try bridge()
        try b.install()
        try Data("T0K\nopen\nhttps://example.com\n".utf8).write(to: b.mailbox.appendingPathComponent("req.1.1"))
        try Data("T0K\nopen\nhttps://second.example\n".utf8).write(to: b.mailbox.appendingPathComponent(".req.2"))  // still being written
        var ran: [[String]] = []
        b.drain(which: { _ in nil }, run: { ran.append($0) }, warn: { _ in })
        b.drain(which: { _ in nil }, run: { ran.append($0) }, warn: { _ in })
        #expect(ran == [["/usr/bin/open", "https://example.com"]])
    }
}

@Suite struct ShellSessionTests {
    @Test func loginShellRestoresPathAndPutsHelpersFirst() throws {
        let script = Engine.loginShell[2]
        #expect(script.contains(#"TITAN_PATH="${TITAN_VM_BIN:+$TITAN_VM_BIN:}$PATH""#))
        #expect(script.contains("/etc/profile.d/zz-titan-path.sh"))
        // The hook, as a login shell would run it after /etc/profile reset PATH.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "TITAN_PATH=/opt/titan/tools/node/bin:/usr/bin; PATH=/usr/bin:/bin; \(Engine.pathHook); echo $PATH"]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "/opt/titan/tools/node/bin:/usr/bin\n")
    }

    @Test func shellSessionSetsUpTheBridgeAndCleansUp() throws {
        let t = try TempProject(["package.json": "{}"])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        try engine.up()
        rt.execs = []
        rt.execExitCode = 3
        let code = try engine.shell(cwd: t.project.root.path, which: { _ in nil })
        #expect(code == 3)                                           // the shell's exit code comes back
        let session = try #require(rt.execs.last)
        #expect(session.env["TITAN_OPEN_DIR"] == "/workspaces/\(t.project.name)/.titan/open")
        #expect(session.env["BROWSER"]?.hasSuffix("/.titan/vm-bin/xdg-open") == true)
        #expect(FileManager.default.isExecutableFile(atPath: t.project.stateDir.appendingPathComponent("vm-bin/code").path))
        #expect(!FileManager.default.fileExists(atPath: t.project.stateDir.appendingPathComponent("open").path))  // mailbox removed
    }

    @Test func optInUserSetupInstallsThePathHook() {
        #expect(VMUser(name: "ann", uid: 501, home: "/home/ann").setupScript(project: "shop").contains("zz-titan-path.sh"))
    }
}
