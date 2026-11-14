import Foundation
import Testing
@testable import TitanCore

@Suite struct ResourcesTests {
    let gib: UInt64 = 1 << 30

    @Test func defaultMemoryIsHalfRamCappedAt8G() {
        #expect(Resources.defaultMemory(hostBytes: 16 * gib) == "8G")
        #expect(Resources.defaultMemory(hostBytes: 64 * gib) == "8G")
        #expect(Resources.defaultMemory(hostBytes: 8 * gib) == "4G")
        #expect(Resources.defaultMemory(hostBytes: 1 * gib) == "1G")
    }

    @Test func parsesAndFormatsSizes() {
        #expect(Resources.parseBytes("8G") == 8 * gib)
        #expect(Resources.parseBytes("512m") == 512 << 20)
        #expect(Resources.parseBytes("2GiB") == 2 * gib)
        #expect(Resources.parseBytes("1024") == 1024)
        #expect(Resources.parseBytes("lots") == nil)
        #expect(Resources.formatBytes(77_078_528) == "74 MB")
        #expect(Resources.formatBytes(gib) == "1.0 GB")
        #expect(Resources.formatBytes(512) == "512 B")
    }

    @Test func cpuPercentUsesTheDeltaBetweenSamples() {
        let a = VMStats(cpuUsageUsec: 1_000_000), b = VMStats(cpuUsageUsec: 3_000_000)
        #expect(Resources.cpuPercent(a, b, interval: 1) == 200)
        #expect(Resources.cpuPercent(b, a, interval: 1) == 0)  // counter reset (VM restarted)
        #expect(Resources.cpuPercent(a, b, interval: 0) == 0)
    }

    // Shapes captured from container 1.7.1.
    @Test func parsesContainerJSON() throws {
        let stats = #"[{"blockReadBytes":48828416,"blockWriteBytes":1789952,"cpuUsageUsec":1503921,"cpuUtilization":0,"id":"x","memoryLimitBytes":1073741824,"memoryUsageBytes":77078528,"networkRxBytes":1661708,"networkTxBytes":48946,"numProcesses":2}]"#
        let s = try #require(AppleContainerRuntime.parseStats(JSONSerialization.jsonObject(with: Data(stats.utf8))))
        #expect(s.cpuUsageUsec == 1503921 && s.memoryLimitBytes == gib && s.processes == 2)

        let inspect = #"[{"configuration":{"image":{"descriptor":{"digest":"sha256:4209"}},"resources":{"cpuOverhead":1,"cpus":4,"memoryInBytes":1073741824}},"id":"x","status":{"state":"running"}}]"#
        let r = try #require(AppleContainerRuntime.parseResources(JSONSerialization.jsonObject(with: Data(inspect.utf8))))
        #expect(r == VMResources(cpus: 4, memoryBytes: gib, imageDigest: "sha256:4209"))

        let images = #"[{"configuration":{"descriptor":{"digest":"sha256:other"}},"variants":[{"platform":{"architecture":"arm64"},"size":1}]},{"configuration":{"descriptor":{"digest":"sha256:4209"}},"variants":[{"platform":{"architecture":"amd64"},"size":5},{"platform":{"architecture":"arm64"},"size":293394205}]}]"#
        #expect(AppleContainerRuntime.parseImageSize(try JSONSerialization.jsonObject(with: Data(images.utf8)), digest: "sha256:4209") == 293394205)

        let df = #"{"containers":{"total":1},"images":{"active":1,"reclaimable":6677889024,"sizeInBytes":8182112256,"total":9}}"#
        #expect(AppleContainerRuntime.parseImageStoreUsage(try JSONSerialization.jsonObject(with: Data(df.utf8)))
                == ImageStoreUsage(count: 9, sizeBytes: 8182112256, reclaimableBytes: 6677889024))
    }

    @Test func newVMsGetTheDefaultMemoryUnlessConfigured() throws {
        let t = try TempProject(["package.json": "{}"])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt).up()
        #expect(rt.runs.first?.memory == Resources.defaultMemory())

        let t2 = try TempProject([".devcontainer.json": #"{"image":"alpine","customizations":{"titan":{"memory":"2G"}}}"#])
        let rt2 = FakeRuntime()
        try makeEngine(t2.project, rt2).up()
        #expect(rt2.runs.first?.memory == "2G")
    }

    @Test func statsSamplesTwiceAndRequiresARunningVM() throws {
        let t = try TempProject(["package.json": "{}"])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        #expect(throws: TitanError.self) { try engine.stats(interval: 0) }

        rt.containers[t.project.containerName] = .running
        rt.statSamples = [VMStats(cpuUsageUsec: 0), VMStats(cpuUsageUsec: 500, memoryUsageBytes: 42)]
        rt.vmResources = VMResources(cpus: 4, memoryBytes: 8 * gib)
        let r = try engine.stats(interval: 0.01)
        #expect(r.sample.memoryUsageBytes == 42)
        #expect(r.cpuPercent > 0)
        #expect(r.resources?.cpus == 4)
        #expect(rt.statSamples.isEmpty)
    }
}
