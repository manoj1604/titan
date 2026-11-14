import Foundation

/// Serves Dev Container `features` (node, python) from the shared toolchain store.
extension Engine {
    public struct PreparedToolchain: Sendable, Equatable {
        public var request: ToolchainRequest
        public var volume: String
        public var source: String
    }

    /// Pins each toolchain's source image (titan.lock) and makes sure its volume exists
    /// and is complete, filling it once if needed. Returns what to mount.
    func prepareToolchains(_ env: ResolvedEnvironment) throws -> [PreparedToolchain] {
        guard !env.toolchainList.isEmpty else { return [] }
        var lock = Lockfile.load(project)
        var changed = false
        var prepared: [PreparedToolchain] = []
        for req in env.toolchainList {
            let image = Toolchain.sourceImage(req)
            var digest = lock?.toolchains?[req.kind.rawValue].flatMap { $0.image == image ? $0.digest : nil }
            if digest == nil {
                // Prefer the build already on this Mac (its volume is probably filled too);
                // otherwise pull once to learn the digest.
                if runtime.imageDigest(image) == nil {
                    console.step("Pulling \(image)")
                    try runtime.pull(image)
                }
                guard let d = runtime.imageDigest(image) else {
                    throw TitanError.message("Couldn't read the digest of \(image) to pin it.")
                }
                digest = d
                var l = lock ?? Lockfile(image: Self.lockImageName(env), digest: nil)
                var pins = l.toolchains ?? [:]
                pins[req.kind.rawValue] = .init(image: image, digest: d)
                l.toolchains = pins
                lock = l
                changed = true
            }
            let pinned = "\(image)@\(digest!)"
            let volume = Toolchain.volumeName(req, digest: digest!)
            try ensureToolchainVolume(volume, request: req, source: pinned)
            prepared.append(PreparedToolchain(request: req, volume: volume, source: pinned))
        }
        if changed, persist, let lock { try lock.save(project) }
        return prepared
    }

    /// Marker on the Mac saying a volume was filled completely (a crash mid-fill leaves no
    /// marker, so the half-filled volume is rebuilt next time).
    func toolchainMarker(_ volume: String) -> URL {
        paths.caches.appendingPathComponent("toolchains/\(volume).ready")
    }

    func ensureToolchainVolume(_ volume: String, request: ToolchainRequest, source: String) throws {
        let marker = toolchainMarker(volume)
        if runtime.volumeExists(volume), FileManager.default.fileExists(atPath: marker.path) { return }
        guard persist else { return }  // dry-run: report only
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Two projects may need the same toolchain at once: serialize on the Mac (where
        // file locks work, unlike inside VMs on shared folders).
        let lockPath = marker.deletingPathExtension().appendingPathExtension("lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw TitanError.message("Can't create \(lockPath).") }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        if runtime.volumeExists(volume), FileManager.default.fileExists(atPath: marker.path) { return }  // filled meanwhile

        if runtime.volumeExists(volume) { try runtime.deleteVolume(volume) }  // incomplete leftover
        console.step("Installing \(request.kind.rawValue) \(request.version) into the shared toolchain store (once per Mac)…")
        try runtime.pull(source)
        try runtime.createVolume(volume)
        let code = try runtime.runToCompletion(image: source, mounts: [Mount(hostPath: volume, guestPath: "/out", isVolume: true)],
                                               command: ["/bin/sh", "-c", Toolchain.fillScript(request.kind)])
        guard code == 0 else {
            try? runtime.deleteVolume(volume)
            throw TitanError.message("Installing \(request.kind.rawValue) \(request.version) failed (exit \(code)).")
        }
        try Data(source.utf8).write(to: marker)
    }

    func toolchainMounts(_ prepared: [PreparedToolchain]) -> [Mount] {
        prepared.map { Mount(hostPath: $0.volume, guestPath: Toolchain.guestPath($0.request.kind), readOnly: true, isVolume: true) }
    }

    /// Volumes still needed by a project (from its lockfile), for `titan gc`.
    static func toolchainVolumes(for project: Project) -> Set<String> {
        guard let lock = Lockfile.load(project), let pins = lock.toolchains else { return [] }
        var result = Set<String>()
        for (kind, pin) in pins {
            guard let k = Toolchain.Kind(rawValue: kind) else { continue }
            // Version as written in the source image tag: node:22-bookworm-slim → 22.
            let tag = pin.image.split(separator: ":").last.map(String.init) ?? ""
            let version = tag.split(separator: "-").first.map(String.init) ?? tag
            result.insert(Toolchain.volumeName(ToolchainRequest(kind: k, version: version), digest: pin.digest))
        }
        return result
    }
}
