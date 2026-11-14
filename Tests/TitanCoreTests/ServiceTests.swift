import Foundation
import Testing
@testable import TitanCore

@Suite struct ServiceConfigTests {
    func env(_ json: String) throws -> ResolvedEnvironment {
        let t = try TempProject([".devcontainer.json": json])
        return try EnvironmentResolver.resolve(t.project)
    }

    @Test func listShorthandUsesPresets() throws {
        let e = try env(#"{"image":"node:22","customizations":{"titan":{"services":["postgres","redis:7"]}}}"#)
        #expect(e.serviceList.map(\.name) == ["postgres", "redis"])
        let pg = e.serviceList[0]
        #expect(pg.image == "postgres:16-bookworm" && pg.port == 5432 && pg.data == "/var/lib/postgresql/data")
        #expect(pg.appEnv["DATABASE_URL"] == "postgres://postgres:postgres@postgres:5432/app")
        #expect(e.serviceList[1].image == "redis:7")   // an explicit tag is kept
        #expect(e.serviceList[1].appEnv["REDIS_URL"] == "redis://redis:6379")
    }

    @Test func mapFormWithOverrides() throws {
        let e = try env(#"""
        {"image":"node:22","customizations":{"titan":{"services":{
          "db": {"image":"postgres:15","env":{"POSTGRES_PASSWORD":"s3cret","POSTGRES_DB":"shop"}},
          "search": {"image":"getmeili/meilisearch:v1.8","port":7700,"data":"/meili_data"}
        }}}}
        """#)
        let db = try #require(e.serviceList.first { $0.name == "db" })
        #expect(db.appEnv["DATABASE_URL"] == "postgres://postgres:s3cret@db:5432/shop")   // follows overrides
        let search = try #require(e.serviceList.first { $0.name == "search" })
        #expect(search.port == 7700 && search.data == "/meili_data" && search.appEnv.isEmpty)
    }

    @Test func rejectsBadNamesAndMissingImages() {
        #expect(throws: TitanError.self) { try ResolvedService.resolve(name: "My_DB", config: ServiceConfig(image: "postgres")) }
        #expect(throws: TitanError.self) { try ResolvedService.resolve(name: "db", config: ServiceConfig()) }
    }

    @Test func servicesDontChangeTheAppHash() throws {
        // Same workspaceFolder: temp projects get random folder names, which feed the default.
        let plain = try env(#"{"image":"node:22","workspaceFolder":"/w"}"#)
        let withDB = try env(#"{"image":"node:22","workspaceFolder":"/w","customizations":{"titan":{"services":["postgres"]}}}"#)
        #expect(plain.configHash == withDB.configHash)
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("services"))
    }
}

@Suite struct ServiceEngineTests {
    let config = #"{"image":"node:22","forwardPorts":[3000],"postCreateCommand":"npm run migrate","customizations":{"titan":{"services":["postgres","redis"]}}}"#

    @Test func upStartsServicesBeforeTheAppAndWiresThemIn() throws {
        let t = try TempProject([".devcontainer.json": config])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        try engine.up()
        let base = t.project.containerName

        // Services start before the app VM, without the workspace, with data on a volume.
        #expect(rt.runs.map(\.name) == ["\(base)-postgres", "\(base)-redis", base])
        let pg = rt.runs[0]
        #expect(pg.hostPath == nil && pg.command.isEmpty)
        #expect(pg.mounts == [Mount(hostPath: "\(base)-postgres-data", guestPath: "/var/lib/postgresql/data")])
        #expect(pg.ports == [.same(5432)])
        #expect(pg.env["PGDATA"] == "/var/lib/postgresql/data/pgdata")
        #expect(rt.volumes == ["\(base)-postgres-data", "\(base)-redis-data"])

        // /etc/hosts is written before postCreate, which then sees DATABASE_URL.
        let hosts = try #require(rt.execs.firstIndex { $0.name == base && $0.command.last?.contains("titan-service") == true })
        let migrate = try #require(rt.execs.firstIndex { $0.command.last == "npm run migrate" })
        #expect(hosts < migrate)
        #expect(rt.execs[migrate].env["DATABASE_URL"] == "postgres://postgres:postgres@postgres:5432/app")
        #expect(rt.execs[migrate].env["REDIS_URL"] == "redis://redis:6379")

        // Service images are pinned alongside the app image.
        let lock = try #require(Lockfile.load(t.project))
        #expect(lock.image == "node:22" && lock.services?["postgres"]?.image == "postgres:16-bookworm")
        #expect(ProjectState.load(t.project)?.services?.keys.sorted() == ["postgres", "redis"])
    }

    @Test func secondUpReusesPinsAndRunningServices() throws {
        let t = try TempProject([".devcontainer.json": config])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt).up()
        rt.runs = []
        try makeEngine(t.project, rt).up()
        #expect(rt.runs.isEmpty)
    }

    @Test func removedServiceIsDeletedButItsDataKept() throws {
        let t = try TempProject([".devcontainer.json": config])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt).up()
        try Data(#"{"image":"node:22","customizations":{"titan":{"services":["postgres"]}}}"#.utf8)
            .write(to: t.url.appendingPathComponent(".devcontainer.json"))
        try makeEngine(t.project, rt).up()
        let redis = "\(t.project.containerName)-redis"
        #expect(rt.calls.contains("remove \(redis)"))
        #expect(rt.volumes.contains("\(redis)-data"))
        #expect(ProjectState.load(t.project)?.services?.keys.sorted() == ["postgres"])
    }

    @Test func downKeepsDataUnlessVolumesIsGiven() throws {
        let t = try TempProject([".devcontainer.json": config])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        try engine.up()
        try engine.down(remove: true)
        #expect(rt.containers.isEmpty)
        #expect(rt.volumes.count == 2)
        try engine.up()
        try engine.down(remove: true, volumes: true)
        #expect(rt.volumes.isEmpty)
    }

    @Test func userEnvBeatsServiceEnv() throws {
        let t = try TempProject([".devcontainer.json": #"{"image":"node:22","remoteEnv":{"DATABASE_URL":"postgres://elsewhere"},"customizations":{"titan":{"services":["postgres"]}}}"#])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        let env = try engine.up()
        #expect(engine.execSpec(command: ["env"], cwd: t.project.root.path, env: env).env["DATABASE_URL"] == "postgres://elsewhere")
    }

    @Test func hostsScriptReplacesOnlyTitanLines() {
        let script = Engine.hostsScript(["192.168.64.5 postgres # titan-service"])
        #expect(script.hasPrefix("grep -v '# titan-service$' /etc/hosts > /tmp/.titan-hosts"))
        #expect(script.contains("'192.168.64.5 postgres # titan-service'"))
        #expect(script.contains("> /etc/hosts"))
    }

    @Test func parsesTheVMAddress() throws {
        let json = #"[{"configuration":{},"status":{"state":"running","networks":[{"ipv4Address":"192.168.64.48/24"}]}}]"#
        #expect(AppleContainerRuntime.parseIPAddress(try JSONSerialization.jsonObject(with: Data(json.utf8))) == "192.168.64.48")
    }

    @Test func gcKeepsServiceImages() throws {
        let paths = tempPaths()
        let t = try TempProject([".devcontainer.json": config])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt, paths: paths).up()
        rt.containers = [:]  // VMs deleted; only the project config/lock remain
        rt.images = [LocalImage(digest: "sha256:abc123", references: ["docker.io/library/postgres:16-bookworm"], sizeBytes: 1),
                     LocalImage(digest: "sha256:r", references: ["docker.io/library/redis:7-bookworm"], sizeBytes: 1)]
        let plan = try GarbageCollector(runtime: rt, paths: paths).plan()
        #expect(plan.titanImages.isEmpty)
        #expect(plan.kept.count == 2)
    }
}
