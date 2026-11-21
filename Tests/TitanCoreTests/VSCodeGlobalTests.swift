import Foundation
import Testing
@testable import TitanCore

@Suite struct VSCodeGlobalTests {
    let titan = "/opt/homebrew/bin/titan"
    let userStyle = """
    {
        "roo-cline.allowedCommands": [
            "npm test",
            "git log"
        ],
        "editor.minimap.enabled": false,
        "[dockercompose]": {
            "editor.insertSpaces": true
        }
    }
    """

    func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vsc-\(UUID().uuidString)/User/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    @Test func addsOnlyTheTwoKeysAndKeepsTheRestByteForByte() throws {
        let url = try file(userStyle)
        #expect(try VSCodeIntegration.installGlobal(settings: url, titan: titan) == .written(url))
        let text = try String(contentsOf: url, encoding: .utf8)
        // Everything the user had is still there, in order and format, up to their last entry.
        #expect(text.hasPrefix(String(userStyle.dropLast(2))))     // all but the final "\n}"
        let s = try json(url)
        #expect(s["terminal.integrated.defaultProfile.osx"] as? String == "Titan")
        let profile = (s["terminal.integrated.profiles.osx"] as? [String: Any])?["Titan"] as? [String: Any]
        #expect(profile?["path"] as? String == titan && profile?["args"] as? [String] == ["shell", "--or-mac"])
        #expect(s["editor.minimap.enabled"] as? Bool == false)
        #expect(FileManager.default.contentsEqual(atPath: url.appendingPathExtension("titan-backup").path, andPath: try file(userStyle).path))
    }

    @Test func runningAgainDoesntDuplicate() throws {
        let url = try file(userStyle)
        _ = try VSCodeIntegration.installGlobal(settings: url, titan: "/old/titan")
        _ = try VSCodeIntegration.installGlobal(settings: url, titan: titan)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.components(separatedBy: "terminal.integrated.profiles.osx").count == 2)
        #expect(text.contains(titan) && !text.contains("/old/titan"))
    }

    @Test func removeRestoresTheOriginalSettings() throws {
        let url = try file(userStyle)
        let before = try json(url)
        _ = try VSCodeIntegration.installGlobal(settings: url, titan: titan)
        #expect(try VSCodeIntegration.removeGlobal(settings: url))
        #expect(NSDictionary(dictionary: try json(url)).isEqual(to: before))
        #expect(try !VSCodeIntegration.removeGlobal(settings: url))     // nothing left to remove
    }

    @Test func emptyOrMissingFile() throws {
        let url = try file("")
        _ = try VSCodeIntegration.installGlobal(settings: url, titan: titan)
        #expect(try json(url)["terminal.integrated.defaultProfile.osx"] as? String == "Titan")
    }

    @Test func leavesFilesWithCommentsOrTheirOwnProfilesToTheUser() throws {
        let commented = try file("{\n  // my settings\n  \"a\": 1\n}\n")
        guard case .manual = try VSCodeIntegration.installGlobal(settings: commented, titan: titan) else { Issue.record("should be manual"); return }
        let own = try file(#"{"terminal.integrated.profiles.osx": {"fish": {"path": "/opt/homebrew/bin/fish"}}}"#)
        guard case .manual = try VSCodeIntegration.installGlobal(settings: own, titan: titan) else { Issue.record("should be manual"); return }
        #expect(try String(contentsOf: own, encoding: .utf8).contains("fish"))   // untouched
    }
}

@Suite struct OptInTests {
    @Test func whichFoldersCountAsTitanProjects() throws {
        func optedIn(_ files: [String: String]) throws -> Bool { let t = try TempProject(files); return t.project.isOptedIn }
        #expect(try optedIn([".devcontainer/devcontainer.json": "{}"]))
        #expect(try optedIn(["titan.lock": "{}"]))
        #expect(try optedIn([".titan/state.json": "{}"]))
        #expect(try !optedIn(["package.json": "{}"]))     // a plain repo stays on the Mac
        #expect(try !optedIn(["notes.txt": ""]))
    }
}

@Suite struct HideTitanFolderTests {
    func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vsc-\(UUID().uuidString)/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func exclude(_ url: URL) throws -> [String: Any]? {
        (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["files.exclude"] as? [String: Any]
    }
    func json(_ url: URL) throws -> NSDictionary { NSDictionary(dictionary: try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]) }

    @Test func addsFilesExcludeWhenMissingAndRemovesItAgain() throws {
        let url = try file("{\n    \"editor.minimap.enabled\": false\n}\n")
        let before = try json(url)
        _ = try VSCodeIntegration.setTitanFolderHidden(true, settings: url)
        #expect(try exclude(url)?["**/.titan"] as? Bool == true)
        _ = try VSCodeIntegration.setTitanFolderHidden(true, settings: url)            // idempotent
        #expect(try String(contentsOf: url, encoding: .utf8).components(separatedBy: "**/.titan").count == 2)
        _ = try VSCodeIntegration.setTitanFolderHidden(false, settings: url)
        #expect(try json(url).isEqual(to: before as! [AnyHashable: Any]))                 // back to exactly what it was
    }

    @Test func keepsTheUsersOtherExclusions() throws {
        let url = try file("{\n    \"files.exclude\": {\n        \"**/.git\": true,\n        \"**/node_modules\": true\n    },\n    \"a\": 1\n}\n")
        _ = try VSCodeIntegration.setTitanFolderHidden(true, settings: url)
        let ex = try #require(try exclude(url))
        #expect(ex["**/.git"] as? Bool == true && ex["**/node_modules"] as? Bool == true && ex["**/.titan"] as? Bool == true)
        _ = try VSCodeIntegration.setTitanFolderHidden(false, settings: url)
        let after = try #require(try exclude(url))
        #expect(after.count == 2 && after["**/.titan"] == nil)
    }

    @Test func emptyExcludeObject() throws {
        let url = try file(#"{"files.exclude": {}, "b": 2}"#)
        _ = try VSCodeIntegration.setTitanFolderHidden(true, settings: url)
        #expect(try exclude(url)?["**/.titan"] as? Bool == true)
        _ = try VSCodeIntegration.setTitanFolderHidden(false, settings: url)
        #expect(try exclude(url) == nil)
    }

    @Test func commentsMeanManual() throws {
        let url = try file("{\n  // mine\n  \"a\": 1\n}")
        guard case .manual = try VSCodeIntegration.setTitanFolderHidden(true, settings: url) else { Issue.record("expected manual"); return }
    }
}
