import Foundation
import Testing
@testable import TitanCore

@Suite struct ToolchainConfigTests {
    @Test func featuresBecomeToolchains() throws {
        let reqs = try Toolchain.requests(from: [
            "ghcr.io/devcontainers/features/node:1": FeatureOptions(version: "20"),
            "ghcr.io/devcontainers/features/python": FeatureOptions(version: "lts"),
        ])
        #expect(reqs == [ToolchainRequest(kind: .node, version: "20"), ToolchainRequest(kind: .python, version: "3.12")])
        #expect(throws: TitanError.self) { try Toolchain.requests(from: ["ghcr.io/devcontainers/features/docker-in-docker:2": FeatureOptions(version: nil)]) }
    }

    @Test func numericVersionsDecode() throws {
        let c = try DevContainerConfig.parse(#"{"image":"x","features":{"ghcr.io/devcontainers/features/python:1":{"version":3.12},"ghcr.io/devcontainers/features/node:1":"22"}}"#)
        #expect(c.features?["ghcr.io/devcontainers/features/python:1"]?.version == "3.12")
        #expect(c.features?["ghcr.io/devcontainers/features/node:1"]?.version == "22")
    }

    @Test func noFeaturesLeavesTheHashAlone() throws {
        let t = try TempProject([".devcontainer.json": #"{"image":"node:22","workspaceFolder":"/w"}"#])
        let json = String(decoding: try JSONEncoder().encode(try EnvironmentResolver.resolve(t.project)), as: UTF8.self)
        #expect(!json.contains("toolchains"))
    }

    @Test func environmentPutsWritablePlacesFirst() {
        let env = Toolchain.environment([.node, .python])
        #expect(env["PATH"]!.hasPrefix("/root/.npm-global/bin:/opt/titan/tools/node/bin:/opt/titan/venv/bin:/opt/titan/tools/python/bin:"))
        #expect(env["NPM_CONFIG_PREFIX"] == "/root/.npm-global" && env["LD_LIBRARY_PATH"] == "/opt/titan/tools/python/lib")
        #expect(Toolchain.environment([]).isEmpty)
    }

    @Test func volumeNamesAreContentAddressed() {
        let r = ToolchainRequest(kind: .python, version: "3.12")
        #expect(Toolchain.volumeName(r, digest: "sha256:0123456789abcdef9999") == "titan-tool-python-3-12-0123456789ab")
    }
}

@Suite struct ToolchainEngineTests {
    let config = #"{"image":"buildpack-deps:bookworm","postCreateCommand":"pip install -r requirements.txt","features":{"ghcr.io/devcontainers/features/python:1":{"version":"3.12"}}}"#

    @Test func firstUpFillsTheStoreOnceAndMountsItReadOnly() throws {
        let paths = tempPaths()
        let t = try TempProject([".devcontainer.json": config])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt, paths: paths).up()

        let volume = "titan-tool-python-3-12-abc123"           // FakeRuntime's digest is sha256:abc123
        #expect(rt.volumes.contains(volume))
        #expect(rt.oneOffRuns.count == 1 && rt.oneOffRuns[0].image == "python:3.12-slim-bookworm@sha256:abc123")
        #expect(rt.oneOffRuns[0].command.last?.contains("compileall") == true)
        #expect(FileManager.default.fileExists(atPath: paths.caches.appendingPathComponent("toolchains/\(volume).ready").path))

        let run = try #require(rt.runs.first)
        #expect(run.image == "buildpack-deps:bookworm")
        #expect(run.mounts.contains(Mount(hostPath: volume, guestPath: "/opt/titan/tools/python", readOnly: true, isVolume: true)))
        #expect(run.env["PATH"]?.hasPrefix("/opt/titan/venv/bin:") == true)

        // The venv is made before postCreate's pip install.
        let venv = try #require(rt.execs.firstIndex { $0.command.last == "python3 -m venv /opt/titan/venv" })
        let pip = try #require(rt.execs.firstIndex { $0.command.last == "pip install -r requirements.txt" })
        #expect(venv < pip)
        #expect(Lockfile.load(t.project)?.toolchains?["python"]?.image == "python:3.12-slim-bookworm")
    }

    @Test func otherProjectsShareTheVolume() throws {
        let paths = tempPaths()
        let rt = FakeRuntime()
        let a = try TempProject([".devcontainer.json": config])
        let b = try TempProject([".devcontainer.json": config])
        try makeEngine(a.project, rt, paths: paths).up()
        try makeEngine(b.project, rt, paths: paths).up()
        #expect(rt.oneOffRuns.count == 1)          // filled once per Mac
        #expect(rt.runs.count == 2)
    }

    @Test func halfFilledVolumeIsRebuilt() throws {
        let paths = tempPaths()
        let rt = FakeRuntime()
        rt.volumes = ["titan-tool-python-3-12-abc123"]   // exists, but no "ready" marker (crash mid-fill)
        let t = try TempProject([".devcontainer.json": config])
        try makeEngine(t.project, rt, paths: paths).up()
        #expect(rt.calls.contains("volume delete titan-tool-python-3-12-abc123"))
        #expect(rt.oneOffRuns.count == 1)
    }

    @Test func gcRemovesOnlyUnusedToolchainVolumes() throws {
        let paths = tempPaths()
        let rt = FakeRuntime()
        let t = try TempProject([".devcontainer.json": config])
        try makeEngine(t.project, rt, paths: paths).up()
        rt.volumes.insert("titan-tool-node-20-ffffffffffff")   // left by a deleted project
        rt.volumes.insert("someone-elses-volume")
        let plan = try GarbageCollector(runtime: rt, paths: paths).plan()
        #expect(plan.toolchainVolumes == ["titan-tool-node-20-ffffffffffff"])
        try GarbageCollector(runtime: rt, paths: paths).removeToolchainVolumes(plan.toolchainVolumes)
        #expect(rt.volumes == ["titan-tool-python-3-12-abc123", "someone-elses-volume"])
    }

    @Test func readOnlyVolumeMountArguments() {
        let rt = AppleContainerRuntime(runner: ProcessRunner())
        let args = rt.runArguments(RunSpec(name: "v", image: "i", hostPath: nil, guestPath: nil, ports: [], env: [:], cpus: nil, memory: nil,
                                           mounts: [Mount(hostPath: "titan-tool-node-22-x", guestPath: "/opt/titan/tools/node", readOnly: true, isVolume: true)]))
        #expect(args.contains("type=volume,source=titan-tool-node-22-x,target=/opt/titan/tools/node,readonly"))
    }
}

@Suite struct NewProjectToolchainTests {}

@Suite struct MountLayoutTests {
    @Test func forwarderAndToolchainsDontNest() throws {
        // Regression: the forwarder was mounted read-only at /opt/titan, so the toolchain
        // mount at /opt/titan/tools/node couldn't create its directory (EROFS).
        let t = try TempProject([".devcontainer.json": #"{"image":"buildpack-deps:bookworm","forwardPorts":[3000],"features":{"ghcr.io/devcontainers/features/node:1":{"version":"22"}}}"#])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt, forwarder: .at(URL(fileURLWithPath: "/share"))).up()
        let targets = try #require(rt.runs.first).mounts.map(\.guestPath)
        for a in targets { for b in targets where a != b { #expect(!b.hasPrefix(a + "/"), "\(b) is inside \(a)") } }
        #expect(targets.contains("/opt/titan/fwd") && targets.contains("/opt/titan/tools/node"))
    }
}

@Suite struct ToolchainPullTests {
    @Test func aLocallyAvailableBuildIsReusedWithoutPulling() throws {
        let t = try TempProject([".devcontainer.json": #"{"image":"buildpack-deps:bookworm","features":{"ghcr.io/devcontainers/features/node:1":{"version":"22"}}}"#])
        let rt = FakeRuntime()   // imageDigest returns a digest: "already on this Mac"
        try makeEngine(t.project, rt).up()
        #expect(!rt.calls.contains("pull node:22-bookworm-slim"))
    }
}

@Suite struct LockRefreshTests {
    @Test func refreshKeepsAndUpdatesEveryPin() throws {
        let t = try TempProject([".devcontainer.json": #"{"image":"buildpack-deps:bookworm","features":{"ghcr.io/devcontainers/features/node:1":{"version":"22"}},"customizations":{"titan":{"services":["redis"]}}}"#])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt).up()
        #expect(Lockfile.load(t.project)?.services?["redis"] != nil && Lockfile.load(t.project)?.toolchains?["node"] != nil)

        rt.digest = "sha256:newer"
        let changes = try makeEngine(t.project, rt).refreshLock()
        let lock = try #require(Lockfile.load(t.project))
        #expect(lock.digest == "sha256:newer")
        #expect(lock.services?["redis"]?.digest == "sha256:newer")       // not dropped, refreshed
        #expect(lock.toolchains?["node"]?.digest == "sha256:newer")
        #expect(changes.count == 3)
        #expect(try makeEngine(t.project, rt).refreshLock().isEmpty)     // second run: nothing changed
    }
}
