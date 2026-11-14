import Foundation

/// Services (Postgres, Redis, …): one VM each, data on a named volume that survives
/// `titan rebuild`, reachable from the app VM by service name.
///
/// Apple's container network has no name resolution between VMs and assigns a new IP on
/// every start, so Titan rewrites the app VM's /etc/hosts with current IPs on each `up`.
extension Engine {
    public func serviceContainerName(_ service: String) -> String { "\(name)-\(service)" }
    public func serviceVolumeName(_ service: String) -> String { "\(name)-\(service)-data" }

    static let hostsMarker = "# titan-service"

    /// Creates, starts or recreates each configured service, removes ones no longer
    /// configured (keeping their data), then waits until each accepts connections.
    func upServices(_ env: ResolvedEnvironment, state: inout ProjectState, rebuild: Bool) throws {
        var states = state.services ?? [:]
        for old in states.keys.sorted() where !env.serviceList.contains(where: { $0.name == old }) {
            let cname = serviceContainerName(old)
            if runtime.status(of: cname) != .missing {
                console.step("Removing service \(old) (no longer configured; its data volume is kept)")
                try runtime.remove(cname)
            }
            states[old] = nil
        }

        var lock = Lockfile.load(project)
        var lockChanged = false
        for svc in env.serviceList {
            let cname = serviceContainerName(svc.name)
            var status = runtime.status(of: cname)
            let previous = states[svc.name]
            let drifted = previous.map { $0.configHash != svc.configHash } ?? false
            if status != .missing, rebuild || (drifted && status == .stopped) {
                console.step(rebuild ? "Recreating service \(svc.name)…" : "Service \(svc.name) config changed, recreating…")
                try runtime.remove(cname)
                status = .missing
            }
            if status == .stopped, let previous, previous.ports.contains(where: { !portIsFree($0.host) }) {
                console.step("Service \(svc.name)'s port is now in use; recreating it with a free port…")
                try runtime.remove(cname)
                status = .missing
            }
            switch status {
            case .missing:
                let ports = try allocatePorts(svc.port.map { [$0] } ?? [], strict: false, label: svc.name)
                let image = try prepareServiceImage(svc, env: env, lock: &lock, changed: &lockChanged)
                var mounts: [Mount] = []
                if let data = svc.data {
                    let volume = serviceVolumeName(svc.name)
                    if !runtime.volumeExists(volume) { try runtime.createVolume(volume) }
                    mounts.append(Mount(hostPath: volume, guestPath: data))
                }
                console.step("Starting service \(console.paint(svc.name, "1")) (\(svc.image))")
                try runtime.run(RunSpec(name: cname, image: image, hostPath: nil, guestPath: nil, ports: ports,
                                        env: svc.env, cpus: nil, memory: nil, mounts: mounts, command: svc.command))
                states[svc.name] = .init(configHash: svc.configHash, image: image, ports: ports)
            case .stopped:
                console.step("Starting service \(svc.name)")
                try runtime.start(cname)
            case .running:
                if drifted { console.warn("Service \(svc.name) config changed. Run `titan rebuild` to apply it.") }
            }
        }
        if lockChanged, persist, let lock { try lock.save(project) }
        state.services = states.isEmpty ? nil : states
        for svc in env.serviceList { if let port = svc.port { waitUntilReady(svc, port: port) } }
    }

    /// Pulls the service image, pinned by titan.lock when it has a matching entry.
    func prepareServiceImage(_ svc: ResolvedService, env: ResolvedEnvironment,
                             lock: inout Lockfile?, changed: inout Bool) throws -> String {
        if let pin = lock?.services?[svc.name], pin.image == svc.image {
            console.step("Pulling \(svc.image) (pinned by titan.lock)")
            try runtime.pull(pin.pinnedReference)
            return pin.pinnedReference
        }
        console.step("Pulling \(svc.image)")
        try runtime.pull(svc.image)
        if let digest = runtime.imageDigest(svc.image) {
            var l = lock ?? Lockfile(image: Self.lockImageName(env), digest: nil)
            var pins = l.services ?? [:]
            pins[svc.name] = .init(image: svc.image, digest: digest)
            l.services = pins
            lock = l
            changed = true
        }
        return svc.image
    }

    /// The app image name recorded in a lockfile created for services before the app's own pin.
    static func lockImageName(_ env: ResolvedEnvironment) -> String {
        if case .pull(let ref) = env.image { return ref }
        return "build"
    }

    /// Polls until the service listens on `port` (up to ~60s). Warns rather than fails:
    /// a slow first start (initdb) shouldn't abort `up`.
    func waitUntilReady(_ svc: ResolvedService, port: Int, attempts: Int = 120) {
        let spec = ExecSpec(name: serviceContainerName(svc.name), command: Tunnel.listenProbe(port),
                            workdir: nil, env: [:], interactive: false, tty: false)
        for attempt in 0..<attempts {
            if (try? runtime.exec(spec)) == 0 { return }
            if attempt == 4 { console.step("Waiting for \(svc.name) to accept connections…") }
            Thread.sleep(forTimeInterval: 0.5)
        }
        console.warn("\(svc.name) isn't listening on port \(port) yet; check `container logs \(serviceContainerName(svc.name))`.")
    }

    /// Points each service name at its current IP inside the app VM.
    func writeServiceHosts(_ env: ResolvedEnvironment) throws {
        guard !env.serviceList.isEmpty else { return }
        var lines: [String] = []
        for svc in env.serviceList {
            guard let ip = runtime.ipAddress(of: serviceContainerName(svc.name)) else {
                console.warn("Couldn't get \(svc.name)'s address; the app may not reach it by name.")
                continue
            }
            lines.append("\(ip) \(svc.name) \(Self.hostsMarker)")
        }
        let script = Self.hostsScript(lines)
        let code = try runtime.exec(ExecSpec(name: name, command: ["/bin/sh", "-c", script], workdir: nil,
                                             env: [:], interactive: false, tty: false))
        if code != 0 { console.warn("Couldn't update /etc/hosts in the VM (exit \(code)).") }
    }

    /// Replaces Titan's lines in /etc/hosts in place (it may be a mount, so no rename).
    static func hostsScript(_ lines: [String]) -> String {
        let entries = lines.map { "printf '%s\\n' \(shellQuote($0))" }.joined(separator: "; ")
        return "grep -v '\(hostsMarker)$' /etc/hosts > /tmp/.titan-hosts; "
            + "{ cat /tmp/.titan-hosts; \(entries.isEmpty ? ":" : entries); } > /etc/hosts; rm -f /tmp/.titan-hosts"
    }

    /// Variables the app gets from its services (DATABASE_URL, REDIS_URL…); the first service wins on clashes.
    func serviceEnvironment(_ env: ResolvedEnvironment) -> [String: String] {
        var result: [String: String] = [:]
        for svc in env.serviceList {
            for (k, v) in svc.appEnv where result[k] == nil && env.containerEnv[k] == nil { result[k] = v }
        }
        return result
    }

    func downServices(_ env: ResolvedEnvironment?, remove: Bool, volumes: Bool) throws {
        let names = Set((env?.serviceList.map(\.name) ?? []) + (ProjectState.load(project)?.services?.keys.map { $0 } ?? []))
        for svc in names.sorted() {
            let cname = serviceContainerName(svc)
            switch runtime.status(of: cname) {
            case .missing: break
            case .running where !remove:
                try runtime.stop(cname)
                console.success("Stopped service \(svc)")
            default:
                if remove {
                    try runtime.remove(cname)
                    console.success("Removed service \(svc)" + (volumes ? "" : " (data kept)"))
                }
            }
            if volumes, runtime.volumeExists(serviceVolumeName(svc)) {
                try runtime.deleteVolume(serviceVolumeName(svc))
                console.success("Deleted \(svc)'s data")
            }
        }
    }

    public struct ServiceReport: Sendable {
        public var name: String
        public var image: String
        public var status: ContainerStatus
        public var ports: [PortMapping]
        public var appEnv: [String: String]
    }

    public func serviceReports(_ env: ResolvedEnvironment) -> [ServiceReport] {
        let states = ProjectState.load(project)?.services ?? [:]
        return env.serviceList.map { svc in
            let status = runtime.status(of: serviceContainerName(svc.name))
            let ports = status == .missing ? (svc.port.map { [PortMapping.same($0)] } ?? []) : (states[svc.name]?.ports ?? [])
            return ServiceReport(name: svc.name, image: svc.image, status: status, ports: ports, appEnv: svc.appEnv)
        }
    }
}
