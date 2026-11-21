import Foundation
import Testing
@testable import TitanCore

@Suite struct LogsTests {
    func engine(_ config: String) throws -> (Engine, FakeRuntime, ResolvedEnvironment, TempProject) {
        let t = try TempProject([".devcontainer.json": config])
        let rt = FakeRuntime()
        let e = makeEngine(t.project, rt)
        let env = try e.up()
        return (e, rt, env, t)
    }

    @Test func pickingWhatToShow() throws {
        let (e, _, env, t) = try engine(#"{"image":"node:22","customizations":{"titan":{"services":["postgres","redis"]}}}"#)
        _ = t
        #expect(try e.logsTarget(service: "redis", boot: false, env: env) == .service("redis"))
        #expect(try e.logsTarget(service: nil, boot: false, env: env) == .choose(["postgres", "redis"]))
        #expect(try e.logsTarget(service: nil, boot: true, env: env) == .appBoot)
        #expect(throws: TitanError.self) { try e.logsTarget(service: "mysql", boot: false, env: env) }
    }

    @Test func aSingleServiceIsTheDefault() throws {
        let (e, rt, env, t) = try engine(#"{"image":"node:22","customizations":{"titan":{"services":["postgres"]}}}"#)
        let target = try e.logsTarget(service: nil, boot: false, env: env)
        #expect(target == .service("postgres"))
        _ = try e.showLogs(target, follow: true, lines: 50, boot: false)
        let call = try #require(rt.logCalls.last)
        #expect(call.name == "\(t.project.containerName)-postgres" && call.follow && call.lines == 50 && !call.boot)
    }

    @Test func bootLogIsTheAppVM() throws {
        let (e, rt, _, t) = try engine(#"{"image":"node:22"}"#)
        _ = try e.showLogs(.appBoot, follow: false, lines: nil, boot: true)
        #expect(rt.logCalls.last?.name == t.project.containerName && rt.logCalls.last?.boot == true)
    }

    @Test func containerArguments() {
        #expect(AppleContainerRuntime.logsArguments(name: "vm", follow: true, lines: 20, boot: false) == ["container", "logs", "--follow", "-n", "20", "vm"])
        #expect(AppleContainerRuntime.logsArguments(name: "vm", follow: false, lines: nil, boot: true) == ["container", "logs", "--boot", "vm"])
    }

    @Test func insideTheVMWithoutFollow() throws {
        let t = try TempProject(["package.json": "{}"])
        let b = OpenBridge(project: t.project, workspace: "/workspaces/x", token: "T")
        #expect(b.titanAction(["logs", "postgres", "-n", "20"], titan: "/t") == .run(["/t", "-C", t.project.root.path, "logs", "postgres", "-n", "20"]))
        guard case .refuse = b.titanAction(["logs", "postgres", "-f"], titan: "/t") else { Issue.record("-f should be refused"); return }
    }
}
