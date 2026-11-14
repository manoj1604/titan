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
