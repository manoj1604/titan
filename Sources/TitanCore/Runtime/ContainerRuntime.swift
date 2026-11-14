import Foundation

public enum ContainerStatus: String, Sendable {
    case missing, stopped, running
}

public struct RunSpec: Equatable, Sendable {
    public var name: String
    public var image: String
    public var hostPath: String
    public var guestPath: String
    public var ports: [Int]
    public var env: [String: String]
    public var cpus: Int?
    public var memory: String?
    /// Keeps the VM alive between `exec`s.
    public var command: [String] = ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done"]
}

public struct ExecSpec: Equatable, Sendable {
    public var name: String
    public var command: [String]
    public var workdir: String?
    public var env: [String: String]
    public var interactive: Bool
    public var tty: Bool
}

/// The VM backend. The MVP drives Apple's `container` CLI; a native backend on
/// Containerization.framework can slot in here without touching the engine.
public protocol ContainerRuntime: Sendable {
    var displayName: String { get }
    func isInstalled() -> Bool
    func version() -> String?
    func isSystemRunning() -> Bool
    func startSystem() throws
    func status(of name: String) -> ContainerStatus
    func pull(_ reference: String) throws
    func build(tag: String, dockerfile: String, context: String, args: [String: String]) throws
    func imageDigest(_ reference: String) -> String?
    func run(_ spec: RunSpec) throws
    func start(_ name: String) throws
    func stop(_ name: String) throws
    func remove(_ name: String) throws
    func exec(_ spec: ExecSpec) throws -> Int32
    func execReplacingProcess(_ spec: ExecSpec) throws -> Never
}
