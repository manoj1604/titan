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
}

func makeEngine(_ project: Project, _ runtime: FakeRuntime, tty: Bool = false) -> Engine {
    Engine(project: project, runtime: runtime, console: Console(quiet: true),
           terminal: TerminalInfo(stdinIsTTY: tty, stdoutIsTTY: tty), titanExecutable: "/usr/local/bin/titan")
}
