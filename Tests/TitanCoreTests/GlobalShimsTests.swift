import Foundation
import Testing
@testable import TitanCore

@Suite struct GlobalShimsTests {
    /// Runs `sh -c <cmd>` in `cwd` with PATH = shims dir + a fake "Mac" bin dir.
    func run(_ cmd: String, cwd: URL, shims: URL, macBin: URL, env extra: [String: String] = [:]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = cwd
        p.environment = ["PATH": "\(shims.path):\(macBin.path):/usr/bin:/bin", "HOME": "/nonexistent"].merging(extra) { _, n in n }
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func exe(_ url: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func routesByTheFolderItRunsIn() throws {
        let t = try TempProject(["package.json": "{}", "src/x.ts": ""])
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gs-\(UUID().uuidString)")
        let shims = base.appendingPathComponent("shims"), macBin = base.appendingPathComponent("macbin")
        try GlobalShims.ensure(commands: ["npm"], in: shims, titan: "/nonexistent/titan")
        try exe(macBin.appendingPathComponent("npm"), "echo mac-npm \"$@\"")
        try exe(t.project.root.appendingPathComponent(".titan/bin/npm"), "echo vm-npm \"$@\"")

        // In the project (and its subfolders): the project's shim, i.e. the VM.
        #expect(try run("npm test", cwd: t.project.root, shims: shims, macBin: macBin) == "vm-npm test")
        #expect(try run("npm i", cwd: t.project.root.appendingPathComponent("src"), shims: shims, macBin: macBin) == "vm-npm i")
        // Elsewhere: the Mac's npm, with our folder removed from PATH (no loop).
        #expect(try run("npm -v", cwd: base, shims: shims, macBin: macBin) == "mac-npm -v")
        // TITAN_DISABLE: the Mac's.
        #expect(try run("npm -v", cwd: t.project.root, shims: shims, macBin: macBin, env: ["TITAN_DISABLE": "1"]) == "mac-npm -v")
    }

    @Test func aProjectWithoutThatCommandUsesTheMac() throws {
        let t = try TempProject(["pyproject.toml": ""])
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gs-\(UUID().uuidString)")
        let shims = base.appendingPathComponent("shims"), macBin = base.appendingPathComponent("macbin")
        try GlobalShims.ensure(commands: ["npm"], in: shims, titan: "/nonexistent/titan")
        try exe(macBin.appendingPathComponent("npm"), "echo mac-npm")
        try exe(t.project.root.appendingPathComponent(".titan/bin/python"), "echo vm-python")
        #expect(try run("npm", cwd: t.project.root, shims: shims, macBin: macBin) == "mac-npm")
    }

    @Test func leavesOtherFilesAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gs-\(UUID().uuidString)")
        try exe(dir.appendingPathComponent("node"), "echo mine")
        try GlobalShims.ensure(commands: ["node", "../evil"], in: dir, titan: "/t")
        #expect(try String(contentsOf: dir.appendingPathComponent("node"), encoding: .utf8).contains("echo mine"))
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("evil").path))
    }

    @Test func pathBlockGoesFirstAndIsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("eval \"$(/opt/homebrew/bin/brew shellenv)\"\n".utf8).write(to: home.appendingPathComponent(".zprofile"))
        let changed = try GlobalShims.installPath(shell: "zsh", home: home, dir: "/x/shims")
        #expect(changed.map(\.lastPathComponent) == [".zshenv", ".zprofile", ".profile"])
        #expect(try GlobalShims.installPath(shell: "zsh", home: home, dir: "/x/shims").isEmpty)
        let zprofile = try String(contentsOf: home.appendingPathComponent(".zprofile"), encoding: .utf8)
        #expect(zprofile.hasPrefix("eval \"$(/opt/homebrew/bin/brew shellenv)\"\n"))     // after brew, so it wins
        #expect(GlobalShims.isInstalled(shell: "zsh", home: home))
        // The block moves the folder to the front even if something pushed it back, in zsh and bash.
        let real = home.appendingPathComponent("shims").path
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        for sh in ["/bin/zsh", "/bin/bash"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: sh)
            p.arguments = (sh.hasSuffix("zsh") ? ["-f"] : ["--noprofile", "--norc"]) + ["-c", GlobalShims.pathBlock(dir: real) + "\nprintf %s \"$PATH\""]
            p.environment = ["PATH": "/usr/bin:\(real):/bin"]
            let out = Pipe(); p.standardOutput = out
            try p.run(); p.waitUntilExit()
            #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "\(real):/usr/bin:/bin", "\(sh)")
        }
    }
}
