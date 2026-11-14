import Foundation
@testable import TitanCore

/// A temporary project directory, removed on deinit.
final class TempProject {
    let url: URL
    init(_ files: [String: String] = [:]) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("titan-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (path, content) in files { try write(path, content) }
    }
    func write(_ path: String, _ content: String) throws {
        let f = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: f)
    }
    var project: Project { Project(root: url) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

struct ReplacedProcess: Error { let spec: ExecSpec }

/// In-memory runtime that records what the engine asked for.
final class FakeRuntime: ContainerRuntime, @unchecked Sendable {
    var installed = true
    var systemRunning = true
    var containers: [String: ContainerStatus] = [:]
    var calls: [String] = []
    var execs: [ExecSpec] = []
    var runs: [RunSpec] = []
    var execExitCode: Int32 = 0
    var digest: String? = "sha256:abc123"
    var statSamples: [VMStats] = []
    var vmResources: VMResources?
    var images: [LocalImage] = []
    var digestsInUse: Set<String> = []
    var deleted: [String] = []
    var volumes: Set<String> = []
    var ips: [String: String] = [:]
    var containerInfo: [ContainerInfo]?
    var statsByName: [String: VMStats] = [:]

    var displayName: String { "fake" }
    func isInstalled() -> Bool { installed }
    func version() -> String? { "fake 1.0" }
    func isSystemRunning() -> Bool { systemRunning }
    func startSystem() throws { calls.append("system start"); systemRunning = true }
    func status(of name: String) -> ContainerStatus { containers[name] ?? .missing }
    func pull(_ reference: String) throws { calls.append("pull \(reference)") }
    func build(tag: String, dockerfile: String, context: String, args: [String: String]) throws { calls.append("build \(tag)") }
    func imageDigest(_ reference: String) -> String? { digest }
    func run(_ spec: RunSpec) throws { calls.append("run \(spec.name)"); runs.append(spec); containers[spec.name] = .running }
    func start(_ name: String) throws { calls.append("start \(name)"); containers[name] = .running }
    func stop(_ name: String) throws { calls.append("stop \(name)"); containers[name] = .stopped }
    func remove(_ name: String) throws { calls.append("remove \(name)"); containers[name] = nil }
    func exec(_ spec: ExecSpec) throws -> Int32 { execs.append(spec); return execExitCode }
    func execReplacingProcess(_ spec: ExecSpec) throws -> Never { throw ReplacedProcess(spec: spec) }
    func stats(of name: String) -> VMStats? { statSamples.isEmpty ? nil : statSamples.removeFirst() }
    func resources(of name: String) -> VMResources? { vmResources }
    func listImages() -> [LocalImage]? { images }
    func imageDigestsInUse() -> Set<String>? { digestsInUse }
    func deleteImages(_ references: [String]) throws { deleted += references }
    func volumeExists(_ name: String) -> Bool { volumes.contains(name) }
    func createVolume(_ name: String) throws { calls.append("volume create \(name)"); volumes.insert(name) }
    func deleteVolume(_ name: String) throws { calls.append("volume delete \(name)"); volumes.remove(name) }
    func listContainers() -> [ContainerInfo]? {
        containerInfo ?? containers.keys.sorted().map {
            ContainerInfo(name: $0, image: "img", status: containers[$0]!, memoryLimitBytes: 1 << 30, publishedPorts: [])
        }
    }
    func allStats() -> [String: VMStats]? { statsByName }
    func ipAddress(of name: String) -> String? { ips[name] ?? (containers[name] == .running ? "192.168.64.9" : nil) }
}

/// Machine-wide Titan paths in a throwaway folder, so tests never touch ~/Library.
func tempPaths() -> TitanPaths {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("titan-home-\(UUID().uuidString)")
    return TitanPaths(support: base.appendingPathComponent("support"), caches: base.appendingPathComponent("caches"))
}

/// By default every port counts as free, so tests don't depend on what this Mac is running;
/// port tests pass `Ports.isFree` to exercise real sockets.
func makeEngine(_ project: Project, _ runtime: FakeRuntime, tty: Bool = false,
                paths: TitanPaths = tempPaths(),
                portIsFree: @escaping @Sendable (Int) -> Bool = { _ in true },
                forwarder: Engine.ForwarderSource = .disabled) -> Engine {
    Engine(project: project, runtime: runtime, console: Console(quiet: true),
           terminal: TerminalInfo(stdinIsTTY: tty, stdoutIsTTY: tty), titanExecutable: "/usr/local/bin/titan",
           paths: paths, portIsFree: portIsFree, forwarder: forwarder)
}
