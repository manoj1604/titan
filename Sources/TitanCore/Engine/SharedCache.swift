import Foundation

/// Package-manager caches shared by every VM through one host folder, so ten Node
/// projects download each package once instead of ten times.
///
/// Only caches that stay consistent WITHOUT file locks are shared: `flock` on a
/// virtiofs mount is not honoured across VMs (verified on container 1.7.1), so two
/// VMs writing a lock-based cache (cargo, gradle, maven, uv, Go build cache) at the
/// same time could corrupt it. These three use atomic renames / checksums instead.
public enum SharedCache {
    public static let guestPath = "/titan-cache"

    public struct Tool: Sendable, Equatable {
        public var name: String
        public var variable: String
        public var subdirectory: String
    }

    public static let tools: [Tool] = [
        Tool(name: "npm", variable: "npm_config_cache", subdirectory: "npm"),        // cacache: content-addressed, lockless
        Tool(name: "pip", variable: "PIP_CACHE_DIR", subdirectory: "pip"),           // atomic temp-file + rename writes
        Tool(name: "go modules", variable: "GOMODCACHE", subdirectory: "go-mod"),     // verified against go.sum on use
    ]

    /// Variables pointing each tool at the shared mount.
    public static var environment: [String: String] {
        Dictionary(uniqueKeysWithValues: tools.map { ($0.variable, "\(guestPath)/\($0.subdirectory)") })
    }

    /// Bytes used per tool (and anything else) under the host cache folder.
    public static func usage(_ paths: TitanPaths) -> [(name: String, url: URL, bytes: UInt64)] {
        let fm = FileManager.default
        let root = paths.sharedCache
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let name = tools.first { $0.subdirectory == url.lastPathComponent }?.name ?? url.lastPathComponent
                return (name, url, allocatedSize(of: url))
            }
    }

    /// Empties the shared cache. The folder itself stays (running VMs have it mounted).
    /// Go marks its module cache read-only, so write access is restored first.
    public static func clean(_ paths: TitanPaths) throws {
        let fm = FileManager.default
        let root = paths.sharedCache
        guard fm.fileExists(atPath: root.path) else { return }
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                try? fm.setAttributes([.posixPermissions: isDir ? 0o755 : 0o644], ofItemAtPath: url.path)
            }
        }
        for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try fm.removeItem(at: child)
        }
        for tool in tools {
            try fm.createDirectory(at: root.appendingPathComponent(tool.subdirectory), withIntermediateDirectories: true)
        }
    }

    static func allocatedSize(of url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walker {
            let v = try? file.resourceValues(forKeys: Set(keys))
            if v?.isRegularFile == true { total += UInt64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
