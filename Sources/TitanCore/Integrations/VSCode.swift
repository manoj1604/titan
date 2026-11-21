import Foundation

/// Makes VS Code's integrated terminal open inside the project VM.
public enum VSCodeIntegration {
    public static let profileName = "Titan VM"

    public enum Outcome: Equatable, Sendable {
        case written(URL)
        /// settings.json has comments we would destroy; caller should show the snippet.
        case manual(snippet: String)
    }

    public static func profile(titan: String) -> [String: Any] {
        ["path": titan, "args": ["shell"], "icon": "vm"]
    }

    public static func snippet(titan: String) -> String {
        let obj: [String: Any] = [
            "terminal.integrated.profiles.osx": [profileName: profile(titan: titan)],
            "terminal.integrated.defaultProfile.osx": profileName,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Global (every Titan project)

    /// The profile VS Code uses everywhere: a VM shell in Titan projects, the normal Mac shell elsewhere.
    public static let globalProfileName = "Titan"

    public static func globalProfile(titan: String) -> [String: Any] {
        ["path": titan, "args": ["shell", "--or-mac"], "icon": "vm"]
    }

    /// VS Code's user settings file.
    public static func userSettingsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser, app: String = "Code") -> URL {
        home.appendingPathComponent("Library/Application Support/\(app)/User/settings.json")
    }

    public static func globalSnippet(titan: String) -> String {
        let obj: [String: Any] = [
            "terminal.integrated.profiles.osx": [globalProfileName: globalProfile(titan: titan)],
            "terminal.integrated.defaultProfile.osx": globalProfileName,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Adds the global profile to VS Code's user settings with a minimal text edit: the user's
    /// other settings keep their order and formatting, and a backup is written first. Falls back
    /// to `.manual` when the file has comments or already defines terminal profiles.
    public static func installGlobal(settings url: URL, titan: String) throws -> Outcome {
        let fm = FileManager.default
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard JSONC.removeComments(original) == original,
                  let obj = try? JSONSerialization.jsonObject(with: Data(JSONC.strip(original).utf8)) as? [String: Any] else {
                return .manual(snippet: globalSnippet(titan: titan))
            }
            if let profiles = obj["terminal.integrated.profiles.osx"] as? [String: Any], profiles[globalProfileName] == nil {
                return .manual(snippet: globalSnippet(titan: titan))   // the user has their own profiles; don't rewrite them
            }
        }
        let block = Self.globalBlock(titan: titan, indent: Self.indent(of: original))
        var updated: String
        if trimmed.isEmpty || trimmed == "{}" {
            updated = "{\n" + block + "\n}\n"
        } else if let existing = original.range(of: #""terminal\.integrated\.profiles\.osx"[\s\S]*?"terminal\.integrated\.defaultProfile\.osx"\s*:\s*"[^"]*""#, options: .regularExpression),
                  original[existing].contains("\"\(globalProfileName)\"") {
            updated = original.replacingCharacters(in: existing, with: block.trimmingCharacters(in: .whitespaces))  // refresh our own block
        } else {
            // Insert before the final "}", adding a comma after the previous last entry.
            guard let close = original.range(of: "}", options: .backwards) else { return .manual(snippet: globalSnippet(titan: titan)) }
            var head = String(original[..<close.lowerBound])
            while let last = head.last, last.isWhitespace { head.removeLast() }
            if let last = head.last, last != "{" && last != "," { head += "," }
            updated = head + "\n" + block + "\n" + original[close.lowerBound...]
        }
        guard (try? JSONSerialization.jsonObject(with: Data(updated.utf8))) != nil else {
            return .manual(snippet: globalSnippet(titan: titan))     // never write a file VS Code can't read
        }
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url.appendingPathExtension("titan-backup"))
            try fm.copyItem(at: url, to: url.appendingPathExtension("titan-backup"))
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(updated.utf8).write(to: url, options: .atomic)
        return .written(url)
    }

    /// Removes Titan's global profile (and makes the Mac shell VS Code's default again).
    public static func removeGlobal(settings url: URL) throws -> Bool {
        guard let original = try? String(contentsOf: url, encoding: .utf8),
              let range = original.range(of: #",?\s*"terminal\.integrated\.profiles\.osx"\s*:\s*\{\s*"Titan"\s*:\s*\{[^{}]*\}\s*\}\s*,\s*"terminal\.integrated\.defaultProfile\.osx"\s*:\s*"Titan""#, options: .regularExpression)
        else { return false }
        var updated = original.replacingCharacters(in: range, with: "")
        updated = updated.replacingOccurrences(of: #"\{\s*,"#, with: "{", options: .regularExpression)
        guard (try? JSONSerialization.jsonObject(with: Data(updated.utf8))) != nil else { return false }
        try Data(updated.utf8).write(to: url, options: .atomic)
        return true
    }

    // MARK: Hiding .titan in the editor

    public static let titanFolderPattern = "**/.titan"

    /// Hides (or shows again) `.titan` in the editor's explorer, search and quick-open via
    /// `files.exclude`, keeping any other exclusions the user has. Same minimal-edit rules as
    /// installGlobal: backup first, never write invalid JSON, comments → `.manual`.
    public static func setTitanFolderHidden(_ hidden: Bool, settings url: URL) throws -> Outcome {
        let snippet = #"  "files.exclude": { "**/.titan": true }"#
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? "{}"
        guard JSONC.removeComments(original) == original,
              let obj = try? JSONSerialization.jsonObject(with: Data(JSONC.strip(original).utf8)) as? [String: Any] else {
            return .manual(snippet: snippet)
        }
        let exclude = obj["files.exclude"] as? [String: Any]
        let isHidden = (exclude?[titanFolderPattern] as? Bool) == true
        if hidden == isHidden { return .written(url) }   // already as asked
        let i = indent(of: original)
        var updated = original
        if hidden {
            if exclude != nil, let open = original.range(of: #""files\.exclude"\s*:\s*\{"#, options: .regularExpression) {
                let empty = exclude!.isEmpty
                updated.insert(contentsOf: "\n\(i)\(i)\"\(titanFolderPattern)\": true" + (empty ? "\n\(i)" : ","), at: open.upperBound)
            } else {
                guard let appended = appendTopLevel(original, "\(i)\"files.exclude\": { \"\(titanFolderPattern)\": true }") else {
                    return .manual(snippet: snippet)
                }
                updated = appended
            }
        } else {
            // Drop our entry (with whichever comma goes with it), then an emptied files.exclude.
            updated = updated.replacingOccurrences(of: #"\s*"\*\*/\.titan"\s*:\s*(true|false)\s*,"#, with: "", options: .regularExpression)
            updated = updated.replacingOccurrences(of: #",\s*"\*\*/\.titan"\s*:\s*(true|false)"#, with: "", options: .regularExpression)
            updated = updated.replacingOccurrences(of: #"\s*"\*\*/\.titan"\s*:\s*(true|false)\s*"#, with: "", options: .regularExpression)
            updated = updated.replacingOccurrences(of: #",\s*"files\.exclude"\s*:\s*\{\s*\}"#, with: "", options: .regularExpression)
            updated = updated.replacingOccurrences(of: #""files\.exclude"\s*:\s*\{\s*\}\s*,?"#, with: "", options: .regularExpression)
        }
        guard (try? JSONSerialization.jsonObject(with: Data(updated.utf8))) != nil else { return .manual(snippet: snippet) }
        try backup(url)
        try Data(updated.utf8).write(to: url, options: .atomic)
        return .written(url)
    }

    /// Inserts a top-level `"key": value` before the final "}" (adding the needed comma).
    static func appendTopLevel(_ text: String, _ entry: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" { return "{\n" + entry + "\n}\n" }
        guard let close = text.range(of: "}", options: .backwards) else { return nil }
        var head = String(text[..<close.lowerBound])
        while let last = head.last, last.isWhitespace { head.removeLast() }
        if let last = head.last, last != "{" && last != "," { head += "," }
        return head + "\n" + entry + "\n" + text[close.lowerBound...]
    }

    static func backup(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return
        }
        try? fm.removeItem(at: url.appendingPathExtension("titan-backup"))
        try fm.copyItem(at: url, to: url.appendingPathExtension("titan-backup"))
    }

    static func indent(of text: String) -> String {
        for line in text.split(separator: "\n") where line.hasPrefix(" ") || line.hasPrefix("\t") {
            return String(line.prefix { $0 == " " || $0 == "\t" })
        }
        return "    "
    }

    static func globalBlock(titan: String, indent i: String) -> String {
        let path = titan.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        \(i)"terminal.integrated.profiles.osx": {
        \(i)\(i)"Titan": { "path": "\(path)", "args": ["shell", "--or-mac"], "icon": "vm" }
        \(i)},
        \(i)"terminal.integrated.defaultProfile.osx": "Titan"
        """
    }

    public static func install(project: Project, titan: String) throws -> Outcome {
        let dir = project.root.appendingPathComponent(".vscode")
        let url = dir.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]

        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let stripped = JSONC.strip(text)
            let hasComments = JSONC.removeComments(text) != text
            guard !hasComments,
                  let obj = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] else {
                return .manual(snippet: snippet(titan: titan))
            }
            settings = obj
        }

        var profiles = settings["terminal.integrated.profiles.osx"] as? [String: Any] ?? [:]
        profiles[profileName] = profile(titan: titan)
        settings["terminal.integrated.profiles.osx"] = profiles
        settings["terminal.integrated.defaultProfile.osx"] = profileName

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        return .written(url)
    }
}
