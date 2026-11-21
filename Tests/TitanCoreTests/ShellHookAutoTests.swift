import Foundation
import Testing
@testable import TitanCore

@Suite struct ShellHookAutoTests {
    func temp() throws -> (URL, TitanPaths) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, TitanPaths(support: dir.appendingPathComponent("support"), caches: dir.appendingPathComponent("caches")))
    }

    @Test func addsTheHookOnceWhenMissing() throws {
        let (home, paths) = try temp()
        try Data("export EDITOR=vim\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
        let first = ShellSetup.ensureInstalled(shell: "zsh", home: home, titan: "/opt/homebrew/bin/titan", paths: paths, environment: [:])
        #expect(first == .added(home.appendingPathComponent(".zshrc")))
        let text = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        #expect(text.hasPrefix("export EDITOR=vim\n") && text.contains("titan hook zsh"))
        #expect(ShellSetup.ensureInstalled(shell: "zsh", home: home, titan: "/opt/homebrew/bin/titan", paths: paths, environment: [:]) == .alreadyThere)
    }

    @Test func respectsNoAndOptOuts() throws {
        let (home, paths) = try temp()
        let rc = home.appendingPathComponent(".zshrc")
        #expect(ShellSetup.ensureInstalled(shell: "zsh", home: home, titan: "/t", paths: paths, environment: ["TITAN_NO_SHELL_HOOK": "1"]) == .skipped)
        #expect(ShellSetup.ensureInstalled(shell: "fish", home: home, titan: "/t", paths: paths, environment: [:]) == .skipped)
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        try Data().write(to: ShellSetup.declinedMarker(paths))          // said no in `titan setup`
        #expect(ShellSetup.ensureInstalled(shell: "zsh", home: home, titan: "/t", paths: paths, environment: [:]) == .skipped)
        #expect(!FileManager.default.fileExists(atPath: rc.path))
    }

    @Test func hookPrintsNothingOnCd() throws {
        for shell in ["zsh", "bash"] {
            let script = try #require(ShellHook.script(for: shell, titan: "/t"))
            #expect(!script.contains("→ VM"))
            #expect(script.contains("activate -C \"$found\" --quiet"))
        }
    }
}
