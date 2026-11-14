import Foundation

/// One VM as `container list --all` reports it.
public struct ContainerInfo: Equatable, Sendable {
    public var name: String
    public var image: String
    public var status: ContainerStatus
    public var memoryLimitBytes: UInt64
    /// Mac port → VM port, as published.
    public var publishedPorts: [PortMapping]

    public init(name: String, image: String, status: ContainerStatus, memoryLimitBytes: UInt64, publishedPorts: [PortMapping]) {
        self.name = name
        self.image = image
        self.status = status
        self.memoryLimitBytes = memoryLimitBytes
        self.publishedPorts = publishedPorts
    }
}

/// Everything `titan ps` shows: every Titan VM on this Mac, grouped by project.
public struct Overview: Sendable {
    public struct Row: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case app, service(String), unknown }
        public var project: String
        /// Project folder (nil for VMs Titan can't match to a project).
        public var folder: String?
        public var kind: Kind
        public var vm: String
        public var status: ContainerStatus
        public var image: String
        public var memoryUsedBytes: UInt64?
        public var memoryLimitBytes: UInt64
        /// localhost ports, with the app-side port when different.
        public var ports: [PortMapping]
    }

    public var rows: [Row]

    public var running: Int { rows.filter { $0.status == .running }.count }
    public var stopped: Int { rows.filter { $0.status == .stopped }.count }
    public var memoryInUse: UInt64 { rows.compactMap(\.memoryUsedBytes).reduce(0, +) }

    /// Builds the overview from the registry (which folders are projects), the runtime's
    /// VM list, and one stats call for memory. Titan VMs Titan can't place (folder deleted,
    /// created before the registry) are listed as unknown so nothing stays invisible.
    /// `includeIdle` also lists registered projects that have no VM at the moment.
    public static func build(runtime: ContainerRuntime, paths: TitanPaths = .standard,
                             includeIdle: Bool = false) throws -> Overview {
        guard runtime.isInstalled() else { throw TitanError.runtimeMissing }
        guard let containers = runtime.listContainers() else {
            throw TitanError.message("\(runtime.displayName) cannot list VMs.")
        }
        let stats = runtime.allStats() ?? [:]
        var byName = Dictionary(uniqueKeysWithValues: containers.map { ($0.name, $0) })
        var rows: [Row] = []

        for project in Registry.load(paths).liveProjects {
            let app = project.containerName
            let state = ProjectState.load(project)
            let mine = byName.keys.filter { $0 == app || $0.hasPrefix(app + "-") }.sorted { a, b in
                a == app ? true : (b == app ? false : a < b)  // app first, then services
            }
            if mine.isEmpty {
                if includeIdle {
                    rows.append(Row(project: project.name, folder: project.root.path, kind: .app, vm: app,
                                    status: .missing, image: state?.image ?? "-", memoryUsedBytes: nil,
                                    memoryLimitBytes: 0, ports: []))
                }
                continue
            }
            for name in mine {
                let c = byName.removeValue(forKey: name)!
                let kind: Row.Kind = name == app ? .app : .service(String(name.dropFirst(app.count + 1)))
                let saved: [PortMapping]? = switch kind {
                case .app: state?.ports
                case .service(let svc): state?.services?[svc]?.ports
                case .unknown: nil
                }
                rows.append(Row(project: project.name, folder: project.root.path, kind: kind, vm: name,
                                status: c.status, image: c.image,
                                memoryUsedBytes: c.status == .running ? stats[name]?.memoryUsageBytes : nil,
                                memoryLimitBytes: c.memoryLimitBytes,
                                ports: displayPorts(published: c.publishedPorts, saved: saved)))
            }
        }
        for c in byName.values.sorted(by: { $0.name < $1.name }) where c.name.hasPrefix("titan-") {
            rows.append(Row(project: "?", folder: nil, kind: .unknown, vm: c.name, status: c.status, image: c.image,
                            memoryUsedBytes: c.status == .running ? stats[c.name]?.memoryUsageBytes : nil,
                            memoryLimitBytes: c.memoryLimitBytes, ports: c.publishedPorts))
        }
        return Overview(rows: rows)
    }

    /// What a developer opens: localhost port → the port the app listens on. The forwarder's
    /// internal port (61000+) is an implementation detail, so map it back via saved state.
    static func displayPorts(published: [PortMapping], saved: [PortMapping]?) -> [PortMapping] {
        published.map { p in
            if let s = saved?.first(where: { $0.host == p.host }) { return PortMapping(host: s.host, guest: s.guest) }
            return PortMapping(host: p.host, guest: p.guest)
        }
    }
}
