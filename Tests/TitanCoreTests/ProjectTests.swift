import Foundation
import Testing
@testable import TitanCore

@Suite struct ProjectTests {
    @Test func discoversRootFromSubdirectory() throws {
        let t = try TempProject([".devcontainer.json": "{}", "src/app/main.js": ""])
        let found = Project.discover(from: t.url.appendingPathComponent("src/app"))
        #expect(found == t.project)
    }

    @Test func fallsBackToGitRoot() throws {
        let t = try TempProject(["src/x.txt": ""])
        try FileManager.default.createDirectory(at: t.url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(Project.discover(from: t.url.appendingPathComponent("src")) == t.project)
    }

    @Test func monorepoSubprojectsGetTheirOwnRoot() throws {
        let t = try TempProject(["frontend/package.json": "{}", "frontend/src/a.js": "", "backend/go.mod": "go 1.23\n"])
        try FileManager.default.createDirectory(at: t.url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(Project.discover(from: t.url.appendingPathComponent("frontend/src")).name == "frontend")
        #expect(Project.discover(from: t.url.appendingPathComponent("backend")).name == "backend")
    }

    @Test func workspaceRootBeatsMemberPackage() throws {
        let t = try TempProject(["package.json": #"{"workspaces": ["packages/*"]}"#, "packages/ui/package.json": "{}"])
        try FileManager.default.createDirectory(at: t.url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(Project.discover(from: t.url.appendingPathComponent("packages/ui")) == t.project)
    }

    @Test func discoveryStopsAtRepoBoundary() throws {
        // A manifest *above* the git root must not capture the repo.
        let t = try TempProject(["package.json": "{}", "repo/src/x.txt": ""])
        try FileManager.default.createDirectory(at: t.url.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        #expect(Project.discover(from: t.url.appendingPathComponent("repo/src")).name == "repo")
    }

    @Test func containerNameIsStableAndValid() throws {
        let p = Project(root: URL(fileURLWithPath: "/Users/me/Code/My App!"))
        #expect(p.containerName == Project(root: URL(fileURLWithPath: "/Users/me/Code/My App!")).containerName)
        #expect(p.containerName.hasPrefix("titan-my-app-"))
        #expect(p.containerName.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
        #expect(p.containerName != Project(root: URL(fileURLWithPath: "/Users/me/Other/My App!")).containerName)
    }

    @Test func mapsHostPathsIntoGuest() throws {
        let t = try TempProject(["src/a.txt": ""])
        let p = t.project
        let ws = "/workspaces/x"
        #expect(p.guestPath(forHost: p.root.path, workspaceFolder: ws) == ws)
        #expect(p.guestPath(forHost: p.root.path + "/src", workspaceFolder: ws) == ws + "/src")
        #expect(p.guestPath(forHost: "/etc", workspaceFolder: ws) == nil)
        // Sibling directory sharing a prefix must not match.
        #expect(p.guestPath(forHost: p.root.path + "-other", workspaceFolder: ws) == nil)
        #expect(p.translateArgument("--flag", workspaceFolder: ws) == "--flag")
        #expect(p.translateArgument(p.root.path + "/src/a.txt", workspaceFolder: ws) == ws + "/src/a.txt")
    }
}
