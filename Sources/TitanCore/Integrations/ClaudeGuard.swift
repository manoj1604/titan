import Foundation

/// Keeps Claude Code (running on the Mac) working *inside* a Titan project's VM:
/// a PreToolUse hook rewrites every Bash command to `titan run -- bash -c '…'` (so it runs in
/// the VM, with Mac paths of the project translated to the VM's), and refuses file writes
/// outside the project folder. Registered once in ~/.claude/settings.json; outside Titan
/// projects it does nothing. It never approves anything: Claude's own permission rules apply.
public enum ClaudeGuard {
    /// Commands that stay on the Mac: they only touch the project's .git, and pushing needs the
    /// Mac's credentials.
    public static let macCommands: Set<String> = ["git", "gh", "titan"]

    /// The hook's answer for one tool call, or nil to leave it alone.
    public static func decide(_ input: [String: Any], titan: String, home: String,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: Any]? {
        let start = environment["CLAUDE_PROJECT_DIR"] ?? input["cwd"] as? String ?? ""
        guard !start.isEmpty, let project = titanProject(from: start) else { return nil }
        guard let tool = input["tool_name"] as? String, var toolInput = input["tool_input"] as? [String: Any] else { return nil }

        if tool == "Bash" {
            guard let command = toolInput["command"] as? String else { return nil }
            let workspace = (try? EnvironmentResolver.resolve(project))?.workspaceFolder ?? "/workspaces/\(project.name)"
            guard let rewritten = rewrite(command: command, root: project.root.path, workspace: workspace, titan: titan) else { return nil }
            toolInput["command"] = rewritten
            return ["hookSpecificOutput": ["hookEventName": "PreToolUse", "updatedInput": toolInput,
                                           "additionalContext": "Titan: this project runs in its Linux VM; commands run there "
                                               + "(workspace \(workspace)). git, gh and titan run on the Mac."]]
        }
        if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool) {
            guard let path = (toolInput["file_path"] ?? toolInput["notebook_path"]) as? String else { return nil }
            var allowed = [project.root.path, home + "/.claude"]
            if let scratch = input["scratchpad_dir"] as? String { allowed.append(scratch) }
            if isInside(path, any: allowed) { return nil }
            return ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny",
                                           "permissionDecisionReason": "Titan: \(project.name) runs in its VM, so Claude only writes inside "
                                               + "the project folder (\(project.root.path)). \(path) is outside it."]]
        }
        return nil
    }

    /// `npm test` → `'<titan>' run -- bash -c 'npm test'` (sh if the VM has no bash); nil to keep
    /// it on the Mac (git/gh/titan, or already routed).
    public static func rewrite(command: String, root: String, workspace: String, titan: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("titan "), !trimmed.hasPrefix(shellQuote(titan)), !trimmed.hasPrefix(titan + " ") else { return nil }
        if let first = firstWord(of: trimmed), macCommands.contains(first) { return nil }
        let inVM = trimmed.replacingOccurrences(of: root, with: workspace)
        let runner = #"if command -v bash >/dev/null 2>&1; then exec bash -c "$1"; else exec sh -c "$1"; fi"#
        return "\(shellQuote(titan)) run -C \(shellQuote(root)) -- /bin/sh -c \(shellQuote(runner)) titan \(shellQuote(inVM))"
    }

    /// The command word, skipping leading `cd <dir> &&` and VAR=value assignments.
    static func firstWord(of command: String) -> String? {
        var rest = Substring(command)
        while let m = rest.prefixMatch(of: /\s*cd\s+[^;&|]+?\s*&&\s*/) { rest = rest[m.range.upperBound...] }
        let words = rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
        let word = words.first { !$0.contains("=") }.map(String.init)
        return word.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    static func titanProject(from path: String) -> Project? {
        let project = Project.discover(from: URL(fileURLWithPath: path))
        return project.isOptedIn ? project : nil
    }

    static func isInside(_ path: String, any roots: [String]) -> Bool {
        let p = resolved(path)
        return roots.contains { root in
            let r = resolved(root)
            return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
    }

    /// Symlinks resolved even for paths that don't exist yet (a new file): resolve the nearest
    /// existing folder, then add the rest (/var/… → /private/var/…).
    static func resolved(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            rest.insert(url.lastPathComponent, at: 0)
            url = url.deletingLastPathComponent()
        }
        return rest.reduce(url.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    // MARK: Registering the hook in ~/.claude/settings.json

    static let marker = "agent-hook claude"

    public static func hookEntries(titan: String) -> [[String: Any]] {
        let hook: [String: Any] = ["type": "command", "command": "\(shellQuote(titan)) \(marker)"]
        return [["matcher": "Bash", "hooks": [hook]],
                ["matcher": "Edit|Write|MultiEdit|NotebookEdit", "hooks": [hook]]]
    }

    public enum InstallResult: Equatable { case added, updated, unchanged, unreadable }

    /// Adds Titan's two PreToolUse entries (or refreshes them, e.g. after titan moved), keeping
    /// everything else. Refuses to touch a file it can't parse.
    @discardableResult
    public static func install(settings url: URL, titan: String) throws -> InstallResult {
        var root: [String: Any] = [:]
        var existed = false
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
            root = obj
            existed = true
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let hadOurs = pre.contains(where: isOurs)
        pre.removeAll(where: isOurs)
        pre += hookEntries(titan: titan)
        hooks["PreToolUse"] = pre
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if existed, let old = try? Data(contentsOf: url),
           let a = try? JSONSerialization.jsonObject(with: old) as? NSDictionary, a.isEqual(to: root) { return .unchanged }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if existed { try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("titan-backup")) }
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        return hadOurs ? .updated : .added
    }

    public static func uninstall(settings url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any], var pre = hooks["PreToolUse"] as? [[String: Any]] else { return }
        pre.removeAll(where: isOurs)
        if pre.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = pre }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (out + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    public static func isInstalled(settings url: URL) -> Bool {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains(marker)
    }

    static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
    }
}
