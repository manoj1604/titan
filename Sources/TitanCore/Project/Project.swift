import Foundation

/// A directory tree that gets its own VM.
public struct Project: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = Project.canonical(root)
    }

    public var name: String { root.lastPathComponent }
    public var stateDir: URL { root.appendingPathComponent(".titan") }
    public var shimDir: URL { stateDir.appendingPathComponent("bin") }
    public var lockfileURL: URL { root.appendingPathComponent("titan.lock") }

    /// Stable, unique per checkout: two clones of the same repo get different VMs.
    public var containerName: String {
        "titan-\(slug)-\(Hashing.sha256(root.path).prefix(8))"
    }

    public var slug: String {
        let lowered = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return String((collapsed.isEmpty ? "project" : collapsed).prefix(24))
    }

    public var defaultWorkspaceFolder: String { "/workspaces/\(name)" }

    public var devcontainerURL: URL? {
        let candidates = [
            root.appendingPathComponent(".devcontainer/devcontainer.json"),
            root.appendingPathComponent(".devcontainer.json"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Walks up from `start` looking for Titan/devcontainer markers, then a git root.
    public static func discover(from start: URL) -> Project {
        let start = canonical(start)
        let home = canonical(FileManager.default.homeDirectoryForCurrentUser)
        let markers = [".devcontainer/devcontainer.json", ".devcontainer.json", "titan.lock", ".titan/bin"]

        func ancestors() -> [URL] {
            var result: [URL] = []
            var dir = start
            while true {
                result.append(dir)
                if dir.path == "/" || dir == home { break }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
            return result
        }

        let chain = ancestors()
        let fm = FileManager.default
        if let hit = chain.first(where: { dir in markers.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) } }) {
            return Project(root: hit)
        }
        // Search no higher than the repo boundary.
        let gitIndex = chain.firstIndex { fm.fileExists(atPath: $0.appendingPathComponent(".git").path) }
        let scope = gitIndex.map { Array(chain[...$0]) } ?? chain
        // Highest directory with a language manifest: a workspace root beats a member package,
        // while unrelated sibling projects in a monorepo each get their own VM.
        if let manifestRoot = scope.last(where: { dir in
            StackDetector.manifests.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }) {
            return Project(root: manifestRoot)
        }
        if let gitIndex { return Project(root: chain[gitIndex]) }
        return Project(root: start)
    }

    /// Maps a host path inside the project to the corresponding path in the VM.
    public func guestPath(forHost hostPath: String, workspaceFolder: String) -> String? {
        let host = Project.canonical(URL(fileURLWithPath: hostPath)).path
        if host == root.path { return workspaceFolder }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard host.hasPrefix(prefix) else { return nil }
        return workspaceFolder + "/" + host.dropFirst(prefix.count)
    }

    /// Rewrites absolute host paths in command arguments so `titan run cat $PWD/x` just works.
    public func translateArgument(_ arg: String, workspaceFolder: String) -> String {
        guard arg.hasPrefix("/") else { return arg }
        return guestPath(forHost: arg, workspaceFolder: workspaceFolder) ?? arg
    }

    /// Physical path (symlinks resolved, /tmp → /private/tmp) so VM mounts and
    /// cwd mapping agree no matter how the user reached the directory.
    static func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}
