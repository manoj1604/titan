import Foundation
import Testing
@testable import TitanCore

@Suite struct ShellSetupTests {
    func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func addsTheBlockOnceAndKeepsExistingContent() throws {
        let home = try tempHome()
        let rc = home.appendingPathComponent(".zshrc")
        try Data("export EDITOR=vim".utf8).write(to: rc)
        #expect(try ShellSetup.install(into: rc, shell: "zsh", titan: "/opt/titan/bin/titan"))
        #expect(try !ShellSetup.install(into: rc, shell: "zsh", titan: "/opt/titan/bin/titan"))   // idempotent
        let text = try String(contentsOf: rc, encoding: .utf8)
        #expect(text.hasPrefix("export EDITOR=vim\n\n# >>> titan >>>"))
        #expect(text.components(separatedBy: ShellSetup.beginMarker).count == 2)
        #expect(text.contains(#"eval "$(/opt/titan/bin/titan hook zsh)""#))
    }

    @Test func refreshesItsOwnBlockWhenTitanMoves() throws {
        let rc = try tempHome().appendingPathComponent(".zshrc")
        try ShellSetup.install(into: rc, shell: "zsh", titan: "/old/titan")
        #expect(try ShellSetup.install(into: rc, shell: "zsh", titan: "/new/titan"))
        let text = try String(contentsOf: rc, encoding: .utf8)
        #expect(text.contains("/new/titan") && !text.contains("/old/titan"))
    }

    @Test func leavesAHandWrittenHookAlone() throws {
        let rc = try tempHome().appendingPathComponent(".zshrc")
        try Data("eval \"$(titan hook zsh)\"\n".utf8).write(to: rc)
        #expect(ShellSetup.state(of: try String(contentsOf: rc, encoding: .utf8)) == .installed)
        #expect(try !ShellSetup.install(into: rc, shell: "zsh", titan: "/x/titan"))
        // A commented-out line doesn't count.
        #expect(ShellSetup.state(of: "# eval \"$(titan hook zsh)\"") == .missing)
    }

    @Test func writesThroughASymlinkedRcFile() throws {
        let home = try tempHome()
        let real = home.appendingPathComponent("dotfiles-zshrc")
        try Data("alias ll='ls -l'\n".utf8).write(to: real)
        let rc = home.appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(at: rc, withDestinationURL: real)
        try ShellSetup.install(into: rc, shell: "zsh", titan: "/x/titan")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rc.path) == real.path)  // still a link
        #expect(try String(contentsOf: real, encoding: .utf8).contains(ShellSetup.beginMarker))
    }

    @Test func bashPrefersBashProfileWhenPresent() throws {
        let home = try tempHome()
        #expect(ShellSetup.rcFile(shell: "bash", home: home).lastPathComponent == ".bashrc")
        try Data().write(to: home.appendingPathComponent(".bash_profile"))
        #expect(ShellSetup.rcFile(shell: "bash", home: home).lastPathComponent == ".bash_profile")
        #expect(ShellSetup.rcFile(shell: "zsh", home: home).lastPathComponent == ".zshrc")
    }

    @Test func theWrittenBlockLoadsTheHookInARealShell() throws {
        let home = try tempHome()
        let fake = home.appendingPathComponent("titan")
        let hook = ShellHook.script(for: "zsh", titan: fake.path)!.replacingOccurrences(of: "'", with: "'\\''")
        try Data("#!/bin/sh\n[ \"$1\" = hook ] && printf '%s\\n' '\(hook)'\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let rc = home.appendingPathComponent(".zshrc")
        try ShellSetup.install(into: rc, shell: "zsh", titan: fake.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "export HOME='\(home.path)'; source '\(rc.path)'; echo HOOK=$TITAN_HOOK; whence -w titan"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.contains("HOOK=zsh"))
        #expect(text.contains("titan: function"))   // `titan` works even if its folder isn't on PATH
    }
}
