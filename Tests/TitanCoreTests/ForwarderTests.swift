import Foundation
import Testing
@testable import TitanCore

@Suite struct ForwarderTests {
    let fwdDir = URL(fileURLWithPath: "/opt/homebrew/share/titan")

    @Test func routesEachForwardThroughItsOwnForwarderPort() {
        let routed = Forwarder.route([.same(3000), PortMapping(host: 5174, guest: 5173)])
        #expect(routed == [PortMapping(host: 3000, guest: 3000, via: 61000), PortMapping(host: 5174, guest: 5173, via: 61001)])
        #expect(Forwarder.command(for: routed) == ["/opt/titan/titan-fwd-linux-arm64", "61000:3000", "61001:5173"])
    }

    @Test func findsTheBinaryNextToAnInstalledOrDevBuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-\(UUID().uuidString)")
        let share = root.appendingPathComponent("share/titan")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let bin = share.appendingPathComponent(Forwarder.binaryName)
        try Data("x".utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let exe = root.appendingPathComponent("bin/titan").path
        #expect(Forwarder.shareDirectory(executable: exe, environment: [:])?.standardizedFileURL == share.standardizedFileURL)
        #expect(Forwarder.shareDirectory(executable: "/nonexistent/bin/titan", environment: [:]) == nil)
        #expect(Forwarder.shareDirectory(executable: "/nonexistent/bin/titan", environment: ["TITAN_SHARE_DIR": share.path]) != nil)
    }

    @Test func newVMsPublishToTheForwarderAndStartIt() throws {
        let t = try TempProject(["package.json": "{}"])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt, forwarder: .at(fwdDir)).up()
        let run = try #require(rt.runs.first)
        #expect(run.ports == [PortMapping(host: 3000, guest: 3000, via: 61000)])
        #expect(run.mounts.contains(Mount(hostPath: fwdDir.path, guestPath: "/opt/titan", readOnly: true)))
        let fwd = try #require(rt.execs.first { $0.detach })
        #expect(fwd.command == ["/opt/titan/titan-fwd-linux-arm64", "61000:3000"])
        #expect(ProjectState.load(t.project)?.ports?.first?.via == 61000)

        // Every later `up` makes sure it's running (a duplicate exits on its own).
        rt.execs = []
        try makeEngine(t.project, rt, forwarder: .at(fwdDir)).up()
        #expect(rt.execs.contains { $0.detach && $0.command.first == Forwarder.guestBinary })
    }

    @Test func withoutTheBinaryPortsArePublishedDirectly() throws {
        let t = try TempProject(["package.json": "{}"])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt, forwarder: .disabled).up()
        #expect(rt.runs.first?.ports == [.same(3000)])
        #expect(!rt.execs.contains { $0.detach })
    }

    @Test func noPortsMeansNoForwarder() throws {
        let t = try TempProject(["Cargo.toml": "[package]\nname='x'\n", ".devcontainer.json": #"{"image":"rust:1"}"#])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt, forwarder: .at(fwdDir)).up()
        #expect(!(rt.runs.first?.mounts.contains { $0.guestPath == "/opt/titan" } ?? true))
        #expect(!rt.execs.contains { $0.detach })
    }

    @Test func runAndExecArguments() {
        let rt = AppleContainerRuntime(runner: ProcessRunner())
        let spec = RunSpec(name: "v", image: "node:22", hostPath: "/p", guestPath: "/w",
                           ports: [PortMapping(host: 3001, guest: 3000, via: 61000)], env: [:], cpus: nil, memory: nil,
                           mounts: [Mount(hostPath: "/share", guestPath: "/opt/titan", readOnly: true)])
        let args = rt.runArguments(spec)
        #expect(args.contains("127.0.0.1:3001:61000"))
        #expect(args.contains("type=bind,source=/share,target=/opt/titan,readonly"))
        let exec = rt.execArguments(ExecSpec(name: "v", command: ["x"], workdir: nil, env: [:], interactive: false, tty: false, detach: true))
        #expect(exec == ["container", "exec", "--detach", "v", "x"])
    }

    @Test func oldStateWithoutViaStillDecodes() throws {
        let json = #"{"containerName":"x","ports":[{"host":3000,"guest":3000}]}"#
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        #expect(state.ports == [.same(3000)] && state.ports?.first?.published == 3000)
    }
}
