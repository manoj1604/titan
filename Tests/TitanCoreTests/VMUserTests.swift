import Foundation
import Testing
@testable import TitanCore

@Suite struct VMUserTests {
    @Test func linuxNamesFromMacNames() {
        #expect(VMUser.linuxName(from: "manoj") == "manoj")
        #expect(VMUser.linuxName(from: "Manoj.Sahu") == "manoj-sahu")
        #expect(VMUser.linuxName(from: "node") == "dev")      // clashes with the node image's user
        #expect(VMUser.linuxName(from: "123") == "dev")
        #expect(VMUser.linuxName(from: "root") == "dev")
    }

    @Test func resolution() {
        #expect(VMUser.resolve(nil) == nil && VMUser.resolve("root") == nil)
        #expect(VMUser.resolve("me", macUser: "Ann", uid: 501) == VMUser(name: "ann", uid: 501, home: "/home/ann"))
        #expect(VMUser.resolve("vscode") == VMUser(name: "vscode", uid: nil, home: nil))   // exists in the image
    }

    @Test func whoRunsCommandsByKindOfProject() throws {
        func user(_ files: [String: String]) throws -> String? { let t = try TempProject(files); return try EnvironmentResolver.resolve(t.project).user }
        #expect(try user(["package.json": "{}"]) == nil)                                                        // zero-config: root
        #expect(try user([".devcontainer.json": #"{"image":"node:22"}"#]) == nil)                               // spec default: root
        #expect(try user([".devcontainer.json": #"{"image":"x","remoteUser":"vscode"}"#]) == "vscode")           // spec remoteUser
        #expect(try user([".devcontainer.json": #"{"image":"x","remoteUser":"vscode","customizations":{"titan":{"user":"me"}}}"#]) == "me")
        #expect(try user([".devcontainer.json": #"{"image":"x","customizations":{"titan":{"user":"root"}}}"#]) == nil)
    }

    @Test func rootProjectsKeepTheirHash() throws {
        let t = try TempProject([".devcontainer.json": #"{"image":"node:22","workspaceFolder":"/w"}"#])
        let json = String(decoding: try JSONEncoder().encode(try EnvironmentResolver.resolve(t.project)), as: UTF8.self)
        #expect(!json.contains("\"user\""))
    }

    @Test func generatedConfigsStayRoot() throws {
        let t = try TempProject(["package.json": "{}"])
        #expect(try DevContainerConfig.parse(EnvironmentResolver.generateDevcontainer(for: t.project)).titan?.user == nil)
        let vite = try #require(ProjectTemplate.find("vite"))
        let plan = try NewProjectPlan.make(name: "shop", folder: t.url, template: vite, runtimeVersion: nil, services: [], localImages: [])
        #expect(try DevContainerConfig.parse(plan.devcontainer()).titan?.user == nil)
    }

    @Test func setupScriptIsValidShellAndSetsThePrompt() throws {
        let script = VMUser(name: "manoj", uid: 501, home: "/home/manoj").setupScript(project: "shop")
        #expect(script.contains("useradd -m -U -u 501 -s /bin/bash manoj"))
        #expect(script.contains("NOPASSWD:ALL") && script.contains("chown -R manoj: /usr/local"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", "-c", script]                       // parse only
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        // Run just the prompt lines against a scratch home and check what lands in .bashrc.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vmu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let promptLine = script.split(separator: "\n").first { $0.hasPrefix("h=") }!
            .replacingOccurrences(of: "h=/home/manoj", with: "h=\(home.path)")
            .replacingOccurrences(of: "; chown manoj: \"$h/.bashrc\" 2>/dev/null || true", with: "")
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/bin/sh")
        q.arguments = ["-c", promptLine]
        try q.run(); q.waitUntilExit()
        let bashrc = try String(contentsOf: home.appendingPathComponent(".bashrc"), encoding: .utf8)
        #expect(bashrc.contains(#"PS1='\u@shop:\w\$ '"#))
    }
}

@Suite struct UserEngineTests {
    let optIn = #"{"image":"node:22","postCreateCommand":"npm install","customizations":{"titan":{"user":"me"}}}"#

    @Test func optInCreatesTheUserAndRunsCommandsAsIt() throws {
        let t = try TempProject([".devcontainer.json": optIn])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        let env = try engine.up()
        let me = try #require(VMUser.resolve("me"))

        let setup = try #require(rt.execs.firstIndex { $0.command.last?.contains("useradd") == true })
        let install = try #require(rt.execs.firstIndex { $0.command.last == "npm install" })
        #expect(setup < install)
        #expect(rt.execs[setup].user == nil)                       // setup runs as root
        #expect(rt.execs[install].user == me.name)                 // postCreate runs as the user
        #expect(rt.execs[install].env["HOME"] == me.home)
        #expect(rt.execs.contains { $0.detach && $0.command.last?.contains("apt-get install -y -qq sudo") == true })
        #expect(ProjectState.load(t.project)?.user == me.name)

        #expect(engine.execSpec(command: ["npm", "test"], cwd: t.project.root.path, env: env).user == me.name)
        #expect(engine.execSpec(command: ["id"], cwd: t.project.root.path, env: env, asRoot: true).user == nil)
    }

    @Test func vmsFromBeforeUserSupportKeepRunningAsRoot() throws {
        let t = try TempProject([".devcontainer.json": optIn])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        let env = try engine.up()
        var state = try #require(ProjectState.load(t.project))
        state.user = nil                                           // as written by an older Titan
        try state.save(t.project)
        #expect(engine.execSpec(command: ["npm", "test"], cwd: t.project.root.path, env: env).user == nil)
    }

    @Test func devcontainerProjectsStayRootByDefault() throws {
        let t = try TempProject([".devcontainer.json": #"{"image":"node:22","postCreateCommand":"apt-get install -y jq"}"#])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt).up()
        #expect(!rt.execs.contains { $0.command.last?.contains("useradd") == true })
        #expect(rt.execs.first { $0.command.last == "apt-get install -y jq" }?.user == nil)
    }

    @Test func toolchainWritablePlacesBelongToTheUser() {
        let me = VMUser(name: "ann", uid: 501, home: "/home/ann")
        #expect(Toolchain.environment([.node], home: me.home)["NPM_CONFIG_PREFIX"] == "/home/ann/.npm-global")
        let steps = Toolchain.setupSteps([.node, .python], user: me)
        #expect(steps.last == "chown -R ann: /home/ann/.npm-global /opt/titan/venv")
    }

    @Test func execArgumentsIncludeTheUser() {
        let rt = AppleContainerRuntime(runner: ProcessRunner())
        var spec = ExecSpec(name: "v", command: ["bash"], workdir: nil, env: [:], interactive: true, tty: true)
        spec.user = "ann"
        #expect(rt.execArguments(spec) == ["container", "exec", "--user", "ann", "--interactive", "--tty", "v", "bash"])
    }
}
