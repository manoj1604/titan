import Foundation

public enum ContainerStatus: String, Sendable {
    case missing, stopped, running
}

public struct RunSpec: Equatable, Sendable {
    public var name: String
    public var image: String
    /// The project folder and where it appears in the VM (nil for service VMs).
    public var hostPath: String?
    public var guestPath: String?
    public var ports: [PortMapping]
    public var env: [String: String]
    public var cpus: Int?
    public var memory: String?
    /// Extra mounts besides the workspace: a host folder or a named volume (`hostPath` = volume name).
    public var mounts: [Mount] = []
    /// Keeps the VM alive between `exec`s. Empty runs the image's own entrypoint (services).
    public var command: [String] = ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done"]
}

/// localhost:`host` on the Mac forwards to `guest` inside the VM.
public struct PortMapping: Codable, Equatable, Sendable, CustomStringConvertible {
    public var host: Int
    public var guest: Int
    /// VM-side port actually published, when the in-VM forwarder relays to `guest`.
    public var via: Int?
    public init(host: Int, guest: Int, via: Int? = nil) {
        self.host = host
        self.guest = guest
        self.via = via
    }
    /// The VM port the Mac's port is published to.
    public var published: Int { via ?? guest }
    public static func same(_ port: Int) -> PortMapping { PortMapping(host: port, guest: port) }
    public var description: String { host == guest ? "\(host)" : "\(host)→\(guest)" }
}

public struct Mount: Equatable, Sendable {
    public var hostPath: String
    public var guestPath: String
    public var readOnly: Bool
    /// `hostPath` names a container volume rather than a Mac folder.
    public var isVolume: Bool
    public init(hostPath: String, guestPath: String, readOnly: Bool = false, isVolume: Bool = false) {
        self.hostPath = hostPath
        self.guestPath = guestPath
        self.readOnly = readOnly
        self.isVolume = isVolume
    }
}

public struct ExecSpec: Equatable, Sendable {
    public var name: String
    public var command: [String]
    public var workdir: String?
    public var env: [String: String]
    public var interactive: Bool
    public var tty: Bool
    /// Start in the background and return immediately.
    public var detach: Bool = false
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

    // Observability (optional; backends that can't report return nil).
    func stats(of name: String) -> VMStats?
    func resources(of name: String) -> VMResources?
    /// Compressed (download) size of the local image whose index digest is `digest`.
    func imageSize(digest: String) -> UInt64?
    func imageStoreUsage() -> ImageStoreUsage?

    // Image housekeeping.
    func listImages() -> [LocalImage]?
    /// Index digests of images that any VM (running or stopped) was created from.
    func imageDigestsInUse() -> Set<String>?
    func deleteImages(_ references: [String]) throws

    // Services.
    func volumeExists(_ name: String) -> Bool
    func createVolume(_ name: String) throws
    func deleteVolume(_ name: String) throws
    /// The VM's IPv4 address on the container network (changes on every start).
    func ipAddress(of name: String) -> String?

    // Overview (`titan ps`).
    func listContainers() -> [ContainerInfo]?
    /// Names of all volumes.
    func listVolumes() -> [String]?
    /// Runs `command` in a throwaway VM from `image` and waits for it (toolchain filling).
    func runToCompletion(image: String, mounts: [Mount], command: [String]) throws -> Int32
    /// Stats for every running VM, keyed by name.
    func allStats() -> [String: VMStats]?
}

public extension ContainerRuntime {
    func stats(of name: String) -> VMStats? { nil }
    func resources(of name: String) -> VMResources? { nil }
    func imageSize(digest: String) -> UInt64? { nil }
    func imageStoreUsage() -> ImageStoreUsage? { nil }
    func listImages() -> [LocalImage]? { nil }
    func imageDigestsInUse() -> Set<String>? { nil }
    func deleteImages(_ references: [String]) throws { throw TitanError.message("\(displayName) cannot delete images.") }
    func volumeExists(_ name: String) -> Bool { false }
    func createVolume(_ name: String) throws { throw TitanError.message("\(displayName) has no volumes.") }
    func deleteVolume(_ name: String) throws { throw TitanError.message("\(displayName) has no volumes.") }
    func ipAddress(of name: String) -> String? { nil }
    func listContainers() -> [ContainerInfo]? { nil }
    func listVolumes() -> [String]? { nil }
    func runToCompletion(image: String, mounts: [Mount], command: [String]) throws -> Int32 {
        throw TitanError.message("\(displayName) can't run one-off VMs.")
    }
    func allStats() -> [String: VMStats]? { nil }
}
