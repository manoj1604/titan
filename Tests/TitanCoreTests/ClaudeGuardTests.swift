import Foundation
import Testing
@testable import TitanCore

@Suite struct ClaudeGuardTests {
    func titanProject() throws -> TempProject {
        let t = try TempProject([".devcontainer.json": #"{"image":"node:22"}"#, "package.json": "{}"])
        return t
    }

    @Test func commandsAreRoutedToTheVM() throws {
        let t = try titanProject()
        let root = t.project.root.path
        let input: [String: Any] = ["tool_name": "Bash", "cwd": root,
                                    "tool_input": ["command": "cat \(root)/package.json && npm test", "description": "d"]]
        let out = try #require(ClaudeGuard.decide(input, titan: "/opt/homebrew/bin/titan", home: "/Users/x", environment: [:]))
        let hso = try #require(out["hookSpecificOutput"] as? [String: Any])
        #expect(hso["permissionDecision"] == nil)                       // never auto-approves
        let updated = try #require(hso["updatedInput"] as? [String: Any])
        #expect(updated["description"] as? String == "d")              // other fields kept
        let cmd = try #require(updated["command"] as? String)
        #expect(cmd.hasPrefix(shellQuote("/opt/homebrew/bin/titan") + " run -C "))
        #expect(cmd.contains("/workspaces/\(t.project.name)/package.json && npm test"))
        #expect(!cmd.contains("\(root)/package.json"))
    }

    @Test func gitAndTitanStayOnTheMac() {
        for c in ["git status", "cd src && git diff", "gh pr list", "titan status", "GIT_PAGER=cat git log"] {
            #expect(ClaudeGuard.rewrite(command: c, root: "/p", workspace: "/workspaces/p", titan: "/t") == nil, "\(c)")
        }
        #expect(ClaudeGuard.rewrite(command: "npm test", root: "/p", workspace: "/workspaces/p", titan: "/t") != nil)
    }

    @Test func rewrittenCommandRunsTheOriginalUnchanged() throws {
        // The VM-side runner must hand the exact command to bash/sh: run it locally with a fake titan.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("titan")
        // fake `titan run -C <root> -- <cmd...>`: drop the first 4 args and run the rest.
        try Data("#!/bin/sh\nshift 4\nexec \"$@\"\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let original = #"x='a b'; [[ -n "$x" ]] && echo "ok:$x" | tr a A; echo "it's" done"#
        let cmd = try #require(ClaudeGuard.rewrite(command: original, root: "/p", workspace: "/w", titan: fake.path))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", cmd]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "ok:A b\nit's done\n")
    }

    @Test func writesOnlyInsideTheProject() throws {
        let t = try titanProject()
        let root = t.project.root.path
        func decide(_ tool: String, _ path: String, key: String = "file_path") -> [String: Any]? {
            ClaudeGuard.decide(["tool_name": tool, "cwd": root, "scratchpad_dir": "/private/tmp/claude-1/s",
                                "tool_input": [key: path, "content": "x"]], titan: "/t", home: "/Users/x", environment: [:])
        }
        #expect(decide("Write", "\(root)/src/a.ts") == nil)
        #expect(decide("Edit", "/Users/x/.claude/projects/p/memory/m.md") == nil)   // Claude's own memory
        #expect(decide("Write", "/private/tmp/claude-1/s/notes.md") == nil)         // its scratchpad
        for (tool, path, key) in [("Write", "/Users/x/.zshrc", "file_path"), ("Edit", "\(root)/../other/x", "file_path"),
                                  ("NotebookEdit", "/tmp/n.ipynb", "notebook_path")] {
            let hso = decide(tool, path, key: key)?["hookSpecificOutput"] as? [String: Any]
            #expect(hso?["permissionDecision"] as? String == "deny", "\(path)")
        }
    }

    @Test func outsideTitanProjectsItDoesNothing() throws {
        let t = try TempProject(["notes.txt": "x"])
        #expect(ClaudeGuard.decide(["tool_name": "Bash", "cwd": t.project.root.path, "tool_input": ["command": "ls"]],
                                   titan: "/t", home: "/Users/x", environment: [:]) == nil)
    }

    @Test func settingsMergeKeepsTheUsersAndIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString)/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"mine.sh"}]}]}}"#.utf8).write(to: url)
        #expect(try ClaudeGuard.install(settings: url, titan: "/t") == .added)
        #expect(try ClaudeGuard.install(settings: url, titan: "/t") == .unchanged)
        #expect(try ClaudeGuard.install(settings: url, titan: "/new/titan") == .updated)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(obj["model"] as? String == "opus")
        let pre = try #require((obj["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 3)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("mine.sh"))
        try ClaudeGuard.uninstall(settings: url)
        #expect(!ClaudeGuard.isInstalled(settings: url))
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("mine.sh"))
        // A file it can't parse is left alone.
        try Data("{ not json".utf8).write(to: url)
        #expect(try ClaudeGuard.install(settings: url, titan: "/t") == .unreadable)
    }
}
