import Foundation

/// Runs one tunnel: titan-gate on 127.0.0.1 in front of the project's port, and cloudflared in
/// front of the gate. Reports the public URL, restarts cloudflared if it drops (a quick tunnel
/// then gets a new URL), stops at the TTL, and cleans up its state on exit. Used in the
/// foreground by `titan share`, and detached by `titan share --background`.
public final class TunnelSupervisor: @unchecked Sendable {
    public let spec: TunnelSpec
    let store: TunnelStore
    let cloudflared: String
    let gatePath: String?
    let say: @Sendable (String) -> Void

    private let lock = NSLock()
    private var gate: Process?
    private var tunnel: Process?
    private var stopping = false
    private var url: String?
    private var urlSignal = DispatchSemaphore(value: 0)
    private let startedAt = Date()
    public var onURL: (@Sendable (String) -> Void)?

    public init(spec: TunnelSpec, store: TunnelStore, cloudflared: String, gatePath: String?,
                say: @escaping @Sendable (String) -> Void = { _ in }) {
        self.spec = spec
        self.store = store
        self.cloudflared = cloudflared
        self.gatePath = gatePath
        self.say = say
    }

    public var expiresAt: Date? { spec.ttlSeconds.map { startedAt.addingTimeInterval(TimeInterval($0)) } }

    /// Starts the gate and the tunnel and waits for the public URL.
    public func start(timeout: TimeInterval = 60) throws -> String {
        if spec.password != nil && gatePath == nil {
            throw TitanError.message("Password protection needs titan-gate, which isn't installed (reinstall Titan).")
        }
        let target: String
        if let gatePath {
            target = "http://127.0.0.1:\(try startGate(gatePath))"
        } else {
            target = spec.upstream
        }
        try startTunnel(target: target)
        guard urlSignal.wait(timeout: .now() + timeout) == .success, let url = currentURL() else {
            stop()
            throw TitanError.message(spec.domain == nil
                ? "cloudflared didn't produce a link in time (check your internet connection)."
                : "The tunnel for \(spec.domain!) didn't connect in time. Check `cloudflared tunnel login` and your connection.")
        }
        return url
    }

    func currentURL() -> String? { lock.lock(); defer { lock.unlock() }; return url }

    private func startGate(_ path: String) throws -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = TunnelPlan.gateArguments(spec: spec, visitLog: store.visitLog(spec.id).path)
        var env = ProcessInfo.processInfo.environment
        if let pw = spec.password { env["TITAN_GATE_PASSWORD"] = pw }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        lock.lock(); gate = p; lock.unlock()
        // First line: "listening 127.0.0.1:53817".
        var line = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
            if line.contains(0x0A) { break }
        }
        let text = String(decoding: line, as: UTF8.self)
        guard let portText = text.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines),
              let port = Int(portText) else {
            p.terminate()
            throw TitanError.message("titan-gate didn't start (\(text.trimmingCharacters(in: .whitespacesAndNewlines))).")
        }
        out.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }  // keep draining
        return port
    }

    private func startTunnel(target: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cloudflared)
        p.arguments = TunnelPlan.cloudflaredArguments(spec: spec, target: target, rewriteHostWithoutGate: gatePath == nil && !spec.keepHost)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let collector = LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            for line in collector.append(data) { self.handle(line) }
        }
        try p.run()
        lock.lock(); tunnel = p; lock.unlock()
    }

    private func handle(_ line: String) {
        var found: String?
        if let domain = spec.domain {
            if TunnelPlan.isConnected(line) { found = "https://\(domain)" }
        } else if let u = Tunnel.publicURL(in: line) {
            found = u
        }
        guard let found else { return }
        lock.lock()
        let isNew = url != found
        url = found
        lock.unlock()
        guard isNew else { return }
        save()
        onURL?(found)
        urlSignal.signal()
    }

    func save() {
        guard let url = currentURL() else { return }
        try? store.save(TunnelRecord(spec: spec, pid: getpid(), url: url, startedAt: startedAt,
                                     expiresAt: expiresAt, visitLog: store.visitLog(spec.id).path))
    }

    /// Blocks until stopped (signal, `stop()`, TTL) or until cloudflared keeps failing.
    public func runUntilStopped() {
        var restarts = 0
        while true {
            lock.lock(); let p = tunnel; let done = stopping; lock.unlock()
            if done { break }
            if let expires = expiresAt, Date() >= expires {
                say("Time's up (\(TunnelPlan.describe(seconds: spec.ttlSeconds ?? 0))): closing the tunnel.")
                break
            }
            if let p, !p.isRunning {
                // On Ctrl-C cloudflared exits a moment before stop() is called; don't call that a drop.
                Thread.sleep(forTimeInterval: 0.5)
                lock.lock(); let stoppedMeanwhile = stopping; lock.unlock()
                if stoppedMeanwhile { break }
                restarts += 1
                guard restarts <= 10 else { say("cloudflared keeps failing; giving up."); break }
                let wait = min(30.0, 2.0 * Double(restarts))
                say("Tunnel dropped; reconnecting in \(Int(wait))s…")
                Thread.sleep(forTimeInterval: wait)
                lock.lock(); let stillRunning = !stopping; lock.unlock()
                if stillRunning, let gatePort = gatePortTarget() { try? startTunnel(target: gatePort) }
                continue
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        stop()
    }

    private func gatePortTarget() -> String? {
        // Reuse what start() connected to: the gate's address is in the tunnel's arguments.
        lock.lock(); defer { lock.unlock() }
        return tunnel?.arguments.flatMap { args in args.firstIndex(of: "--url").map { args[$0 + 1] } }
    }

    /// Stops the tunnel and the gate and removes the state file. Safe to call more than once.
    public func stop() {
        lock.lock()
        let already = stopping
        stopping = true
        let t = tunnel, g = gate
        lock.unlock()
        if already && t?.isRunning != true && g?.isRunning != true { store.remove(spec.id); return }
        for p in [t, g].compactMap({ $0 }) where p.isRunning { p.terminate() }
        for p in [t, g].compactMap({ $0 }) {
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        store.remove(spec.id)
    }
}

/// Splits streamed bytes into lines (called from a pipe's handler queue).
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}
