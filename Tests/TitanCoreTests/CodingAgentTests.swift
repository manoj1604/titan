import Foundation
import Testing
@testable import TitanCore

@Suite struct CodingAgentTests {
    func syntaxOK(_ script: String) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", "-c", script]
        try p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @Test(arguments: CodingAgent.allCases) func scriptsAreValidShell(agent: CodingAgent) throws {
        #expect(try syntaxOK(agent.installScript(update: false)))
        #expect(try syntaxOK(agent.installScript(update: true)))
        #expect(try syntaxOK(agent.sessionCommand(arguments: ["x"], auto: true)[2]))
    }

    @Test func sessionCommandAndEnvironment() {
        let claude = CodingAgent.claude.sessionCommand(arguments: ["-p", "hi there"], auto: true)
        #expect(claude.prefix(2) == ["/bin/sh", "-c"] && claude.suffix(3) == ["titan-agent", "-p", "hi there"])
        #expect(claude[2].contains(#"export CLAUDE_CONFIG_DIR="$C""#) && claude[2].contains("--dangerously-skip-permissions"))
        #expect(!CodingAgent.codex.sessionCommand(arguments: [], auto: false)[2].contains("--dangerously"))
        #expect(CodingAgent.codex.sessionCommand(arguments: [], auto: false)[2].contains(#"export CODEX_HOME="$C""#))

        let env = CodingAgent.claude.sessionEnvironment(auto: true, runsAsRoot: true,
                                                        mac: ["ANTHROPIC_API_KEY": "k", "OPENAI_API_KEY": "o", "HOME": "/Users/x"])
        #expect(env == ["ANTHROPIC_API_KEY": "k", "DISABLE_AUTOUPDATER": "1", "IS_SANDBOX": "1"])
        #expect(CodingAgent.claude.sessionEnvironment(auto: false, runsAsRoot: true, mac: [:])["IS_SANDBOX"] == nil)
        #expect(CodingAgent.codex.sessionEnvironment(auto: true, runsAsRoot: true, mac: ["OPENAI_API_KEY": "o"]) == ["OPENAI_API_KEY": "o"])
    }

    @Test func newVMsGetTheSharedAgentsFolder() throws {
        let t = try TempProject([".devcontainer.json": #"{"image":"node:22"}"#])
        let rt = FakeRuntime()
        let e = makeEngine(t.project, rt)
        _ = try e.up()
        let mount = try #require(rt.runs.last?.mounts.first { $0.guestPath == CodingAgent.guestDirectory })
        #expect(mount.hostPath == e.paths.agents.path && !mount.readOnly)
    }
}
