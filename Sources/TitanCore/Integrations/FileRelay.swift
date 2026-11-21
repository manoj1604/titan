import CoreServices
import CryptoKit
import Foundation

/// Makes hot reload work: edits made on the Mac don't raise file events inside the VM
/// (virtiofs doesn't forward them), so Vite, Next, nodemon, uvicorn --reload… never notice.
/// The relay watches the project on the Mac (FSEvents) and touches each changed file inside
/// the VM, which fires the VM's own watchers and refreshes its view of the file.
///
/// Loop-proof: a touch from the VM shows up on the Mac as another event, but its content is
/// unchanged, so it's skipped (content hash per path). Directory and metadata-only events are
/// ignored. Runs in the background (`titan up` starts it; it exits when the VM stops).
public enum FileRelay {
    /// Folders that are written inside the VM (installs, caches, builds) or are Titan's own.
    public static let ignoredComponents: Set<String> = [
        "node_modules", ".git", ".titan", ".venv", "venv", "__pycache__", "target", ".next", ".nuxt",
        ".svelte-kit", ".turbo", ".cache", ".parcel-cache", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ".gradle", ".DS_Store",
    ]

    /// `src/App.tsx` → true; `node_modules/x/y.js`, `.git/index` → false.
    public static func shouldRelay(relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.contains("\n") else { return false }
        let parts = relativePath.split(separator: "/").map(String.init)
        if parts.contains(where: { ignoredComponents.contains($0) || $0 == ".." }) { return false }
        // Editor temp files (vim swap, JetBrains ___jb_tmp___, Emacs lock) aren't app files.
        let last = parts.last ?? ""
        return !(last.hasSuffix(".swp") || last.hasSuffix(".swx") || last.hasSuffix("~") || last.hasPrefix(".#")
                 || last.contains("___jb_"))
    }

    static let fileFlag = UInt32(kFSEventStreamEventFlagItemIsFile)
    static let contentFlags = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                     | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)

    /// A file event that may have changed content (not a directory, not metadata only).
    public static func isContentEvent(flags: UInt32) -> Bool {
        flags & fileFlag != 0 && flags & contentFlags != 0
    }

    /// The in-VM side: reads workspace-relative paths, one per line, and touches each.
    /// A path that no longer exists (deleted or renamed away) touches its folder instead.
    public static func guestCommand(workspace: String) -> [String] {
        ["/bin/sh", "-c",
         "cd \"$0\" || exit 1; while IFS= read -r p; do "
         + "if [ -e \"$p\" ]; then touch -c -- \"$p\" 2>/dev/null; else touch -c -- \"$(dirname -- \"$p\")\" 2>/dev/null; fi; "
         + "done", workspace]
    }

    /// Decides which events become touches: one per changed file, never for our own touches.
    public final class Filter: @unchecked Sendable {
        let root: String
        let hash: (String) -> String?
        var lastHash: [String: String] = [:]
        let lock = NSLock()

        public init(root: String, hash: @escaping (String) -> String? = Filter.contentHash) {
            self.root = root.hasSuffix("/") ? String(root.dropLast()) : root
            self.hash = hash
        }

        /// Absolute Mac paths + flags → workspace-relative paths to touch in the VM.
        public func paths(for events: [(path: String, flags: UInt32)]) -> [String] {
            lock.lock(); defer { lock.unlock() }
            var out: [String] = []
            for e in events where FileRelay.isContentEvent(flags: e.flags) {
                guard e.path.hasPrefix(root + "/") else { continue }
                let rel = String(e.path.dropFirst(root.count + 1))
                guard FileRelay.shouldRelay(relativePath: rel), !out.contains(rel) else { continue }
                if let h = hash(e.path) {
                    if lastHash[rel] == h { continue }          // same content: our own touch, or a no-op save
                    lastHash[rel] = h
                } else {
                    if lastHash[rel] == "" { continue }         // already relayed its removal
                    lastHash[rel] = ""
                }
                out.append(rel)
            }
            return out
        }

        /// SHA-256 of files up to 8 MB (bigger files: size + mtime); nil if it's gone.
        public static func contentHash(_ path: String) -> String? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular else { return nil }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if size > 8 << 20 {
                return "big:\(size):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            }
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// FSEvents stream on `root`; calls `onEvents` with (path, flags) batches.
    public final class Watcher: @unchecked Sendable {
        let root: String
        let onEvents: ([(path: String, flags: UInt32)]) -> Void
        var stream: FSEventStreamRef?
        let queue = DispatchQueue(label: "titan.relay.fsevents")

        public init(root: String, onEvents: @escaping ([(path: String, flags: UInt32)]) -> Void) {
            self.root = root
            self.onEvents = onEvents
        }

        public func start() -> Bool {
            var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let me = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
                let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                me.onEvents((0..<min(count, list.count)).map { (list[$0], flags[$0]) })
            }
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                               | kFSEventStreamCreateFlagUseCFTypes)
            guard let s = FSEventStreamCreate(nil, callback, &ctx, [root] as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return false }
            FSEventStreamSetDispatchQueue(s, queue)
            stream = s
            return FSEventStreamStart(s)
        }

        public func stop() {
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    // MARK: Background process bookkeeping (pid file in .titan)

    public static func pidFile(_ project: Project) -> URL { project.stateDir.appendingPathComponent("relay.pid") }

    public static func runningPid(_ project: Project, alive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Int32? {
        guard let text = try? String(contentsOf: pidFile(project), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, alive(pid) else { return nil }
        return pid
    }
}

extension FileRelay {
    /// Runs the relay until the VM stops: FSEvents → filter → one long-lived
    /// `container exec -i <vm> sh` that touches paths. Restarts the exec if it dies while the
    /// VM still runs (at most 20 times).
    public static func supervise(project: Project, containerName: String, workspace: String,
                                 container: String = "container", isRunning: @escaping () -> Bool,
                                 tick: (() -> Bool)? = nil, say: @escaping (String) -> Void) {
        let me = getpid()
        try? Persistence.ensureStateDir(project)
        try? "\(me)\n".write(to: pidFile(project), atomically: true, encoding: .utf8)
        defer {
            if runningPid(project) == me { try? FileManager.default.removeItem(at: pidFile(project)) }
        }

        let lock = NSLock()
        var exec: Process?
        var input: FileHandle?
        func spawn() -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [container, "exec", "-i", containerName] + guestCommand(workspace: workspace)
            let pipe = Pipe()
            p.standardInput = pipe
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { say("couldn't start the in-VM side: \(error)"); return false }
            lock.lock(); exec = p; input = pipe.fileHandleForWriting; lock.unlock()
            return true
        }
        guard spawn() else { return }

        let filter = Filter(root: project.root.path)
        let watcher = Watcher(root: project.root.path) { events in
            let paths = filter.paths(for: events)
            guard !paths.isEmpty else { return }
            lock.lock(); let h = input; lock.unlock()
            let data = Data(paths.map { $0 + "\n" }.joined().utf8)
            // A write to a dead exec raises SIGPIPE (ignored below); the loop respawns it.
            try? h?.write(contentsOf: data)
        }
        signal(SIGPIPE, SIG_IGN)
        guard watcher.start() else { say("couldn't watch \(project.root.path)"); return }
        say("relaying file changes: \(project.root.path) → \(containerName):\(workspace)")

        var restarts = 0
        while true {
            Thread.sleep(forTimeInterval: 3)
            guard isRunning() else { say("VM stopped; relay exiting"); break }
            if tick?() == true { break }
            lock.lock(); let dead = !(exec?.isRunning ?? false); lock.unlock()
            if dead {
                restarts += 1
                guard restarts <= 20, spawn() else { say("in-VM side keeps exiting; relay giving up"); break }
            }
        }
        watcher.stop()
        lock.lock(); exec?.terminate(); lock.unlock()
    }
}
