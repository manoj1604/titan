import Foundation
import Testing
@testable import TitanCore

/// Homebrew layout: the real binary lives in a versioned Cellar folder that `brew upgrade`
/// deletes; /opt/homebrew/bin/titan is a stable symlink. Shims and the shell hook must bake
/// in the stable path, while the forwarder is found next to the real binary.
@Suite struct ExecutablePathTests {
    func brewLayout() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brew-\(UUID().uuidString)").resolvingSymlinksInPath()
        let cellar = root.appendingPathComponent("Cellar/titan/0.1.0")
        try FileManager.default.createDirectory(at: cellar.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cellar.appendingPathComponent("share/titan"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        for file in ["bin/titan", "share/titan/\(Forwarder.binaryName)"] {
            let url = cellar.appendingPathComponent(file)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("bin/titan").path,
                                                   withDestinationPath: "../Cellar/titan/0.1.0/bin/titan")
        return root
    }

    @Test func keepsTheStableSymlinkPath() throws {
        let root = try brewLayout()
        let link = root.appendingPathComponent("bin/titan").path
        #expect(ExecutablePath.stable(argv0: "titan", path: "/nope:\(root.path)/bin", fallback: "x") == link)
        #expect(ExecutablePath.stable(argv0: link, path: "", fallback: "x") == link)
        #expect(ExecutablePath.stable(argv0: "bin/titan", path: "", fallback: "x", cwd: root.path) == link)
        #expect(ExecutablePath.stable(argv0: "titan", path: "/nope", fallback: "fb") == "fb")
    }

    @Test func forwarderIsFoundThroughTheSymlink() throws {
        let root = try brewLayout()
        let dir = Forwarder.shareDirectory(executable: root.appendingPathComponent("bin/titan").path, environment: [:])
        #expect(dir?.path == root.appendingPathComponent("Cellar/titan/0.1.0/share/titan").path)
    }
}
