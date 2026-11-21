import Foundation
import Testing
@testable import TitanCore

@Suite struct AgentNotesTests {
    func env(_ t: TempProject) throws -> ResolvedEnvironment { try EnvironmentResolver.resolve(t.project) }
    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    @Test func freshProjectGetsBothFiles() throws {
        let t = try TempProject([".devcontainer.json": #"{"image":"node:22","forwardPorts":[5173],"customizations":{"titan":{"services":["postgres"]}}}"#,
                                 "package.json": "{}"])
        let changed = try AgentNotes.write(project: t.project, env: try env(t), ports: [PortMapping(host: 5174, guest: 5173)])
        #expect(changed.map(\.lastPathComponent) == ["AGENTS.md", "CLAUDE.md"])
        let agents = read(AgentNotes.agentsFile(t.project))
        #expect(agents.contains("## Dev environment (Titan)"))
        #expect(agents.contains("`titan run -- <command>`"))
        #expect(agents.contains("5173 (on the Mac: 5174)") && agents.contains("http://localhost:5174"))
        #expect(agents.contains("`postgres` (port 5432)") && agents.contains("`$DATABASE_URL`"))
        #expect(read(AgentNotes.claudeFile(t.project)) == "@AGENTS.md\n")
        // Idempotent.
        #expect(try AgentNotes.write(project: t.project, env: try env(t), ports: [PortMapping(host: 5174, guest: 5173)]).isEmpty)
    }

    @Test func keepsTheUsersOwnContent() throws {
        let t = try TempProject(["package.json": "{}", "AGENTS.md": "# Rules\n\nUse tabs.\n", "CLAUDE.md": "Be brief.\n"])
        try AgentNotes.write(project: t.project, env: try env(t), ports: [])
        let agents = read(AgentNotes.agentsFile(t.project))
        #expect(agents.hasPrefix("# Rules\n\nUse tabs.\n\n<!-- titan:begin"))
        #expect(read(AgentNotes.claudeFile(t.project)) == "Be brief.\n\n@AGENTS.md\n")
        // Refresh replaces only Titan's block.
        #expect(AgentNotes.refreshIfPresent(project: t.project, env: try env(t), ports: [PortMapping(host: 3000, guest: 3000)]))
        let refreshed = read(AgentNotes.agentsFile(t.project))
        #expect(refreshed.hasPrefix("# Rules\n\nUse tabs.\n") && refreshed.contains("localhost:3000"))
        #expect(refreshed.components(separatedBy: "titan:begin").count == 2)
        // Remove: the user's content stays.
        try AgentNotes.remove(t.project)
        #expect(read(AgentNotes.agentsFile(t.project)) == "# Rules\n\nUse tabs.\n")
        #expect(read(AgentNotes.claudeFile(t.project)).contains("Be brief."))
    }

    @Test func refreshNeverAddsAndRemoveCleansUp() throws {
        let t = try TempProject(["package.json": "{}"])
        #expect(!AgentNotes.refreshIfPresent(project: t.project, env: try env(t), ports: []))
        #expect(!FileManager.default.fileExists(atPath: AgentNotes.agentsFile(t.project).path))
        try AgentNotes.write(project: t.project, env: try env(t), ports: [])
        try AgentNotes.remove(t.project)
        #expect(!FileManager.default.fileExists(atPath: AgentNotes.agentsFile(t.project).path))
        #expect(!FileManager.default.fileExists(atPath: AgentNotes.claudeFile(t.project).path))
    }
}
