import Foundation

/// Stops a project's VMs after a while with no use, freeing their memory (each VM can hold
/// up to 8 GB). The next command starts them again. Checked by the background relay process.
///
/// Idle means all of: no titan session attached (`titan run`/`shell`, shims like `npm run dev`,
/// VS Code terminals), no shared link, the VM's CPU near zero, for the whole timeout.
public enum IdleStop {
    public static let defaultTimeout = 2 * 3600

    /// `"idleStop": "30m"` / `"2h"` / `false` in devcontainer.json, else `TITAN_IDLE_STOP`
    /// (same forms, or `off`), else 2 hours. nil = never stop.
    public static func timeout(config: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        let text = (config ?? environment["TITAN_IDLE_STOP"])?.trimmingCharacters(in: .whitespaces).lowercased()
        guard let text, !text.isEmpty else { return defaultTimeout }
        if ["false", "off", "never", "no", "0"].contains(text) { return nil }
        return TunnelPlan.parseDuration(text) ?? defaultTimeout
    }

    /// The config value: a duration string or `false`.
    public struct Setting: Decodable, Equatable, Sendable {
        public var text: String
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { text = b ? "\(IdleStop.defaultTimeout)" : "off"; return }
            text = try c.decode(String.self)
        }
    }

    // MARK: Sessions (a file per attached titan process in .titan/sessions)

    static func sessionsDir(_ project: Project) -> URL { project.stateDir.appendingPathComponent("sessions") }

    /// Marks this process as using the VM. The pid survives `exec` into `container exec`,
    /// so a `titan run` session stays visible until it ends.
    public static func markSession(_ project: Project, pid: Int32 = getpid()) {
        let dir = sessionsDir(project)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: dir.appendingPathComponent(String(pid)))
    }

    public static func endSession(_ project: Project, pid: Int32 = getpid()) {
        try? FileManager.default.removeItem(at: sessionsDir(project).appendingPathComponent(String(pid)))
    }

    /// Live sessions; files of ended processes are removed.
    public static func activeSessions(_ project: Project, alive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) -> [Int32] {
        let dir = sessionsDir(project)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var live: [Int32] = []
        for n in names {
            guard let pid = Int32(n) else { continue }
            if alive(pid) { live.append(pid) } else { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
        }
        return live
    }

    // MARK: "Why did my VM stop?"

    static func noteFile(_ project: Project) -> URL { project.stateDir.appendingPathComponent("idle-stopped") }

    public static func recordStop(_ project: Project, timeout: Int? = nil) throws {
        try Persistence.ensureStateDir(project)
        try Data((timeout.map(String.init) ?? "").utf8).write(to: noteFile(project))
    }

    /// True (once) if the VM was last stopped for being idle.
    public static func takeStopNote(_ project: Project) -> Bool {
        guard FileManager.default.fileExists(atPath: noteFile(project).path) else { return false }
        try? FileManager.default.removeItem(at: noteFile(project))
        return true
    }

    // MARK: The decision

    /// Tracks how long a VM has been idle across checks.
    public struct Tracker: Sendable {
        public let timeout: Int
        public private(set) var idleSince: Date?
        var lastCPU: UInt64?
        /// CPU use (share of one core) below which the VM counts as quiet.
        public static let quietCPU = 0.03

        public init(timeout: Int) { self.timeout = timeout }

        /// Feeds one check; true when the VM should be stopped now.
        public mutating func check(now: Date, sessions: Int, tunnels: Int, cpuUsec: UInt64?, interval: TimeInterval) -> Bool {
            var busyCPU = false
            if let cpu = cpuUsec, let last = lastCPU, cpu >= last, interval > 0 {
                busyCPU = Double(cpu - last) / 1_000_000 / interval > Self.quietCPU
            }
            lastCPU = cpuUsec
            if sessions > 0 || tunnels > 0 || busyCPU {
                idleSince = nil
                return false
            }
            let since = idleSince ?? now
            idleSince = since
            return now.timeIntervalSince(since) >= TimeInterval(timeout)
        }
    }
}
