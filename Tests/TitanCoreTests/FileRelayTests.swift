import CoreServices
import Foundation
import Testing
@testable import TitanCore

@Suite struct FileRelayTests {
    let file = UInt32(kFSEventStreamEventFlagItemIsFile)
    let modified = UInt32(kFSEventStreamEventFlagItemModified)
    let meta = UInt32(kFSEventStreamEventFlagItemInodeMetaMod)
    let dir = UInt32(kFSEventStreamEventFlagItemIsDir)

    @Test func whichPathsAreRelayed() {
        #expect(FileRelay.shouldRelay(relativePath: "src/App.tsx"))
        #expect(FileRelay.shouldRelay(relativePath: "app/main.py"))
        for no in ["node_modules/react/index.js", ".git/index", ".titan/state.json", "web/.next/x", "a/__pycache__/m.pyc",
                   "src/.App.tsx.swp", "src/App.tsx~", "src/App.tsx___jb_tmp___", "", "../etc/passwd", "a\nb"] {
            #expect(!FileRelay.shouldRelay(relativePath: no), "\(no)")
        }
    }

    @Test func onlyContentChangesOfFiles() {
        #expect(FileRelay.isContentEvent(flags: file | modified))
        #expect(!FileRelay.isContentEvent(flags: file | meta))          // our own touch
        #expect(!FileRelay.isContentEvent(flags: dir | modified))
    }

    @Test func ownTouchesDoNotLoop() {
        var content = ["/p/src/App.tsx": "v1"]
        let f = FileRelay.Filter(root: "/p", hash: { content[$0] })
        #expect(f.paths(for: [("/p/src/App.tsx", file | modified)]) == ["src/App.tsx"])
        // The VM's touch comes back as another event with the same content: skipped.
        #expect(f.paths(for: [("/p/src/App.tsx", file | modified | meta)]).isEmpty)
        content["/p/src/App.tsx"] = "v2"
        #expect(f.paths(for: [("/p/src/App.tsx", file | modified), ("/p/src/App.tsx", file | modified)]) == ["src/App.tsx"])
        // Deleted: relayed once (the VM touches its folder), then quiet.
        content["/p/src/App.tsx"] = nil
        #expect(f.paths(for: [("/p/src/App.tsx", file | UInt32(kFSEventStreamEventFlagItemRemoved))]) == ["src/App.tsx"])
        #expect(f.paths(for: [("/p/src/App.tsx", file | UInt32(kFSEventStreamEventFlagItemRemoved))]).isEmpty)
        #expect(f.paths(for: [("/other/x.ts", file | modified), ("/p/node_modules/a.js", file | modified)]).isEmpty)
    }

    @Test func guestScriptIsValidShell() throws {
        let cmd = FileRelay.guestCommand(workspace: "/workspaces/shop")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", "-c", cmd[2]]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0 && cmd.last == "/workspaces/shop")
    }

    @Test func guestScriptTouchesFilesAndFoldersOfDeletedOnes() throws {
        let t = try TempProject(["src/a.txt": "x"])
        let a = t.project.root.appendingPathComponent("src/a.txt").path
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: a)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)],
                                              ofItemAtPath: t.project.root.appendingPathComponent("src").path)
        let cmd = FileRelay.guestCommand(workspace: t.project.root.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd[0])
        p.arguments = Array(cmd.dropFirst())
        let input = Pipe(); p.standardInput = input
        try p.run()
        input.fileHandleForWriting.write(Data("src/a.txt\nsrc/gone.txt\n".utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        func mtime(_ path: String) -> Double {
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
        #expect(mtime(a) > 1000)
        #expect(mtime(t.project.root.appendingPathComponent("src").path) > 1000)
        #expect(!FileManager.default.fileExists(atPath: t.project.root.appendingPathComponent("src/gone.txt").path))  // -c: never creates
    }

    @Test func pidFileTracksALiveRelay() throws {
        let t = try TempProject(["package.json": "{}"])
        try Persistence.ensureStateDir(t.project)
        #expect(FileRelay.runningPid(t.project) == nil)
        try "\(getpid())\n".write(to: FileRelay.pidFile(t.project), atomically: true, encoding: .utf8)
        #expect(FileRelay.runningPid(t.project) == getpid())
        #expect(FileRelay.runningPid(t.project, alive: { _ in false }) == nil)
    }
}
