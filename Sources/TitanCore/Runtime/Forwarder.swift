import Foundation

/// The in-VM port forwarder (forwarder/main.go). Apple's container port publishing
/// reaches only the VM's network interface, so apps bound to 127.0.0.1 or ::1 (Vite,
/// Django, Flask, Rails…) would be unreachable. Titan publishes each Mac port to a
/// forwarder port (61000+) and the forwarder relays to wherever the app listens.
public enum Forwarder {
    public static let binaryName = "titan-fwd-linux-arm64"
    /// Its own folder: toolchains mount at /opt/titan/tools/…, which can't be created inside
    /// a read-only mount, so /opt/titan itself must stay a normal (writable) directory.
    public static let guestDirectory = "/opt/titan/fwd"
    public static var guestBinary: String { "\(guestDirectory)/\(binaryName)" }
    /// VM-side ports the forwarder listens on; far above typical app ports.
    public static let firstPort = 61000

    /// Folder holding the binary: $TITAN_SHARE_DIR, `<prefix>/share/titan` next to an
    /// installed titan, or `.build/titan-share` for a development build.
    public static func shareDirectory(executable: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [URL] = []
        if let dir = environment["TITAN_SHARE_DIR"], !dir.isEmpty { candidates.append(URL(fileURLWithPath: dir)) }
        // Both the real location (Homebrew: Cellar/titan/<v>/bin → ../share/titan) and the path as
        // invoked (newer SwiftPM: .build/debug is a symlink into .build/out/Products/Debug, while
        // the helpers are built into .build/titan-share).
        let invoked = URL(fileURLWithPath: executable).standardizedFileURL
        for exe in [invoked.resolvingSymlinksInPath(), invoked] {
            let prefix = exe.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(prefix.appendingPathComponent("share/titan"))   // <prefix>/bin/titan
            candidates.append(prefix.appendingPathComponent("titan-share"))   // .build/<config>/titan
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent(binaryName).path) }
    }

    /// Gives each forward a forwarder port. The app keeps its own port untouched.
    public static func route(_ ports: [PortMapping]) -> [PortMapping] {
        ports.enumerated().map { i, p in
            var m = p
            m.via = firstPort + i
            return m
        }
    }

    public static func command(for ports: [PortMapping]) -> [String] {
        [guestBinary] + ports.compactMap { p in p.via.map { "\($0):\(p.guest)" } }
    }
}
