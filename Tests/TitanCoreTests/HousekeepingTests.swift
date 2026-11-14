import Foundation
import Testing
@testable import TitanCore

@Suite struct SharedCacheTests {
    @Test func newVMsMountTheSharedCacheAndGetCacheVariables() throws {
        let t = try TempProject(["package.json": "{}"])
        let rt = FakeRuntime()
        let paths = tempPaths()
        try makeEngine(t.project, rt, paths: paths).up()
        let run = try #require(rt.runs.first)
        #expect(run.mounts == [Mount(hostPath: paths.sharedCache.path, guestPath: "/titan-cache")])
        #expect(run.env["npm_config_cache"] == "/titan-cache/npm")
        #expect(run.env["PIP_CACHE_DIR"] == "/titan-cache/pip")
        #expect(run.env["GOMODCACHE"] == "/titan-cache/go-mod")
        // Lifecycle commands see the variables too.
        #expect(rt.execs.first?.env["npm_config_cache"] == "/titan-cache/npm")
        #expect(FileManager.default.fileExists(atPath: paths.sharedCache.appendingPathComponent("npm").path))
    }

    @Test func projectSettingsWinAndCanOptOut() throws {
        let t = try TempProject([".devcontainer.json": #"{"image":"alpine","containerEnv":{"PIP_CACHE_DIR":"/mine"}}"#])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt).up()
        #expect(rt.runs.first?.env["PIP_CACHE_DIR"] == "/mine")
        #expect(rt.runs.first?.env["npm_config_cache"] == "/titan-cache/npm")

        let t2 = try TempProject([".devcontainer.json": #"{"image":"alpine","customizations":{"titan":{"sharedCache":false}}}"#])
        let rt2 = FakeRuntime()
        try makeEngine(t2.project, rt2).up()
        #expect(rt2.runs.first?.mounts == [])
        #expect(rt2.runs.first?.env["npm_config_cache"] == nil)
    }

    @Test func cleanEmptiesReadOnlyGoCacheButKeepsTheMountedFolder() throws {
        let paths = tempPaths()
        let mod = paths.sharedCache.appendingPathComponent("go-mod/example.com/x@v1")
        try FileManager.default.createDirectory(at: mod, withIntermediateDirectories: true)
        let file = mod.appendingPathComponent("x.go")
        try Data(repeating: 1, count: 10_000).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mod.path)
        #expect(SharedCache.usage(paths).first { $0.name == "go modules" }.map { $0.bytes > 0 } == true)

        try SharedCache.clean(paths)
        #expect(!FileManager.default.fileExists(atPath: mod.path))
        #expect(FileManager.default.fileExists(atPath: paths.sharedCache.appendingPathComponent("go-mod").path))
        #expect(SharedCache.usage(paths).allSatisfy { $0.bytes == 0 })
    }
}

@Suite struct GarbageCollectorTests {
    @Test func normalizesReferences() {
        #expect(GarbageCollector.normalize("python:3.12-bookworm") == "docker.io/library/python:3.12-bookworm")
        #expect(GarbageCollector.normalize("alpine") == "docker.io/library/alpine:latest")
        #expect(GarbageCollector.normalize("me/app:1") == "docker.io/me/app:1")
        #expect(GarbageCollector.normalize("ghcr.io/a/b") == "ghcr.io/a/b:latest")
        #expect(GarbageCollector.normalize("localhost:5000/x:2") == "localhost:5000/x:2")
        #expect(GarbageCollector.normalize("python:3.12@sha256:ab") == "docker.io/library/python@sha256:ab")
        #expect(GarbageCollector.normalize("docker.io/library/python@sha256:ab") == "docker.io/library/python@sha256:ab")
        #expect(GarbageCollector.normalize("titan-local/app:abc") == "titan-local/app:abc")
    }

    @Test func plansWhatToKeepAndRemove() throws {
        let paths = tempPaths()
        // A project that was `titan up`'d and pinned python 3.12 by digest.
        let t = try TempProject(["requirements.txt": "", ".python-version": "3.12\n"])
        try Lockfile(image: "python:3.12-bookworm", digest: "sha256:py312").save(t.project)
        var registry = Registry()
        registry.record(t.project, image: "python:3.12-bookworm@sha256:py312")
        registry.record(Project(root: URL(fileURLWithPath: "/nonexistent/gone")), image: "ruby:3.3-bookworm")
        try registry.save(paths)

        let rt = FakeRuntime()
        rt.images = [
            LocalImage(digest: "sha256:py312", references: ["docker.io/library/python:3.12-bookworm",
                                                           "docker.io/library/python@sha256:py312"], sizeBytes: 354),
            LocalImage(digest: "sha256:node", references: ["docker.io/library/node:22-bookworm"], sizeBytes: 400),
            LocalImage(digest: "sha256:ruby", references: ["docker.io/library/ruby:3.3-bookworm"], sizeBytes: 300),
            LocalImage(digest: "sha256:built", references: ["titan-local/old:abc"], sizeBytes: 10),
            LocalImage(digest: "sha256:mine", references: ["docker.io/library/postgres:16"], sizeBytes: 150),
            LocalImage(digest: "sha256:busy", references: ["docker.io/library/redis:7"], sizeBytes: 50),
        ]
        rt.digestsInUse = ["sha256:busy"]

        let gc = GarbageCollector(runtime: rt, paths: paths)
        let plan = try gc.plan()
        #expect(Set(plan.kept.map(\.image.digest)) == ["sha256:py312", "sha256:busy"])
        #expect(plan.kept.first { $0.image.digest == "sha256:py312" }?.reason == "needed by \(t.project.name)")
        // node: detector family; ruby: from a deleted project; built: titan-local tag.
        #expect(Set(plan.titanImages.map(\.digest)) == ["sha256:node", "sha256:ruby", "sha256:built"])
        #expect(plan.otherImages.map(\.digest) == ["sha256:mine"])

        try gc.remove(plan.titanImages)
        #expect(Set(rt.deleted) == ["docker.io/library/node:22-bookworm", "docker.io/library/ruby:3.3-bookworm",
                                    "titan-local/old:abc"])
    }

    @Test func unlockedProjectKeepsItsDetectedImageByName() throws {
        let paths = tempPaths()
        let t = try TempProject(["go.mod": "go 1.23\n"])
        var registry = Registry()
        registry.record(t.project, image: nil)
        try registry.save(paths)
        let rt = FakeRuntime()
        rt.images = [LocalImage(digest: "sha256:go", references: ["docker.io/library/golang:1.23-bookworm"], sizeBytes: 1)]
        #expect(try GarbageCollector(runtime: rt, paths: paths).plan().kept.count == 1)
    }

    @Test func upRecordsTheProjectInTheRegistry() throws {
        let paths = tempPaths()
        let t = try TempProject(["go.mod": "go 1.23\n"])
        try makeEngine(t.project, FakeRuntime(), paths: paths).up()
        let entry = try #require(Registry.load(paths).projects[t.project.root.path])
        #expect(entry.images == ["golang:1.23-bookworm"])
    }

    @Test func parsesContainerListAndImageList() throws {
        let list = #"[{"configuration":{"id":"a","image":{"descriptor":{"digest":"sha256:4209"},"reference":"x"}},"status":{"state":"stopped"}}]"#
        #expect(AppleContainerRuntime.parseImageDigestsInUse(try JSONSerialization.jsonObject(with: Data(list.utf8))) == ["sha256:4209"])
        let images = #"[{"configuration":{"descriptor":{"digest":"sha256:a"},"name":"docker.io/library/python:3.12"},"variants":[{"platform":{"architecture":"arm64"},"size":7}]},{"configuration":{"descriptor":{"digest":"sha256:a"},"name":"docker.io/library/python@sha256:a"},"variants":[{"platform":{"architecture":"arm64"},"size":7}]}]"#
        let parsed = AppleContainerRuntime.parseImageList(try JSONSerialization.jsonObject(with: Data(images.utf8)))
        #expect(parsed == [LocalImage(digest: "sha256:a", references: ["docker.io/library/python:3.12", "docker.io/library/python@sha256:a"], sizeBytes: 7)])
        #expect(parsed.first?.displayName == "docker.io/library/python:3.12")
    }
}

@Suite struct PortTests {
    /// Listens on a free ephemeral port, like another VM's port forward would.
    final class HeldPort {
        let fd: Int32
        let port: Int
        init() {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            self.fd = fd
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            listen(fd, 1)
            var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            self.port = Int(UInt16(bigEndian: bound.sin_port))
        }
        deinit { close(fd) }
    }

    @Test func busyPortIsRemappedToTheNextFreeHostPort() throws {
        let held = HeldPort()
        #expect(!Ports.isFree(held.port))
        let t = try TempProject([".devcontainer.json": "{\"image\":\"alpine\",\"forwardPorts\":[\(held.port)]}"])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        let env = try engine.up()
        let mapping = try #require(rt.runs.first?.ports.first)
        #expect(mapping.guest == held.port)
        #expect(mapping.host > held.port && mapping.host <= held.port + 100)
        #expect(engine.publishedPorts(env) == [mapping])   // remembered for status / up output
        #expect(env.ports == [held.port])                  // config (and its hash) unchanged
    }

    @Test func strictPortsFailsBeforeAnythingIsCreated() throws {
        let held = HeldPort()
        let t = try TempProject([".devcontainer.json": "{\"image\":\"alpine\",\"forwardPorts\":[\(held.port)],\"customizations\":{\"titan\":{\"strictPorts\":true}}}"])
        let rt = FakeRuntime()
        #expect(throws: TitanError.portsInUse([held.port])) { try makeEngine(t.project, rt).up() }
        #expect(rt.runs.isEmpty && rt.calls.filter { $0.hasPrefix("pull") }.isEmpty)
    }

    @Test func stoppedVMWhosePortWasTakenIsRecreated() throws {
        let t = try TempProject(["package.json": "{}"])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        try engine.up()
        try engine.down(remove: false)
        // Someone else grabs the host port the stopped VM was publishing.
        let held = HeldPort()
        var state = try #require(ProjectState.load(t.project))
        state.ports = [PortMapping(host: held.port, guest: 3000)]
        try state.save(t.project)

        try engine.up()
        #expect(rt.calls.contains("remove \(t.project.containerName)"))
        #expect(rt.runs.count == 2)
        #expect(rt.runs.last?.ports.first?.host != held.port)
    }

    @Test func unchangedConfigHashWithoutStrictPorts() throws {
        // strictPorts is optional so adding the field didn't change every existing VM's hash.
        let t = try TempProject(["package.json": "{}"])
        let env = try EnvironmentResolver.resolve(t.project)
        let json = String(decoding: try JSONEncoder().encode(env), as: UTF8.self)
        #expect(!json.contains("strictPorts"))
    }

    @Test func containerErrorsAreTrimmedToTheErrorLine() {
        let stderr = "[0/6] [0s]\n[6/6] Starting container [1s]\nError: failed to bootstrap container\n[6/6] Starting container [1s]\n"
        #expect(AppleContainerRuntime.errorLine(stderr) == "Error: failed to bootstrap container")
    }
}
