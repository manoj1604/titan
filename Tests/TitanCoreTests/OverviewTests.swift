import Foundation
import Testing
@testable import TitanCore

@Suite struct OverviewTests {
    @Test func groupsVMsByProjectWithServicesAndUnknowns() throws {
        let paths = tempPaths()
        let t = try TempProject([".devcontainer.json": #"{"image":"node:22","forwardPorts":[3000],"customizations":{"titan":{"services":["redis"]}}}"#])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt, paths: paths, forwarder: .at(URL(fileURLWithPath: "/share"))).up()
        let app = t.project.containerName
        rt.containerInfo = [
            ContainerInfo(name: app, image: "node:22", status: .running, memoryLimitBytes: 8 << 30,
                          publishedPorts: [PortMapping(host: 3000, guest: 61000)]),           // via the forwarder
            ContainerInfo(name: "\(app)-redis", image: "redis:7", status: .running, memoryLimitBytes: 1 << 30,
                          publishedPorts: [.same(6379)]),
            ContainerInfo(name: "titan-gone-1234abcd", image: "python:3.12", status: .stopped, memoryLimitBytes: 1 << 30, publishedPorts: []),
            ContainerInfo(name: "someone-elses-vm", image: "alpine", status: .running, memoryLimitBytes: 1 << 30, publishedPorts: []),
        ]
        rt.statsByName = [app: VMStats(memoryUsageBytes: 100 << 20), "\(app)-redis": VMStats(memoryUsageBytes: 30 << 20)]

        let o = try Overview.build(runtime: rt, paths: paths)
        #expect(o.rows.map(\.vm) == [app, "\(app)-redis", "titan-gone-1234abcd"])   // non-titan VMs ignored
        #expect(o.rows[0].kind == .app && o.rows[0].folder == t.project.root.path)
        #expect(o.rows[0].ports == [.same(3000)])          // forwarder port 61000 mapped back to the app's 3000
        #expect(o.rows[1].kind == .service("redis"))
        #expect(o.rows[2].kind == .unknown && o.rows[2].folder == nil)
        #expect(o.running == 2 && o.stopped == 1)
        #expect(o.memoryInUse == 130 << 20)
    }

    @Test func idleProjectsOnlyWithAll() throws {
        let paths = tempPaths()
        let t = try TempProject(["go.mod": "go 1.23\n"])
        var registry = Registry()
        registry.record(t.project, image: "golang:1.23-bookworm")
        try registry.save(paths)
        let rt = FakeRuntime()
        #expect(try Overview.build(runtime: rt, paths: paths).rows.isEmpty)
        let all = try Overview.build(runtime: rt, paths: paths, includeIdle: true)
        #expect(all.rows.count == 1 && all.rows[0].status == .missing)
    }

    @Test func parsesContainerList() throws {
        let json = #"[{"configuration":{"id":"titan-x","image":{"reference":"docker.io/library/node:22"},"resources":{"memoryInBytes":8589934592},"publishedPorts":[{"containerPort":61000,"hostPort":3000}]},"status":{"state":"running"}},{"configuration":{"id":"titan-y","image":{"reference":"r"},"resources":{"memoryInBytes":1}},"status":"stopped"}]"#
        let list = AppleContainerRuntime.parseContainerList(try JSONSerialization.jsonObject(with: Data(json.utf8)))
        #expect(list == [
            ContainerInfo(name: "titan-x", image: "docker.io/library/node:22", status: .running, memoryLimitBytes: 8 << 30,
                          publishedPorts: [PortMapping(host: 3000, guest: 61000)]),
            ContainerInfo(name: "titan-y", image: "r", status: .stopped, memoryLimitBytes: 1, publishedPorts: []),
        ])
    }
}
