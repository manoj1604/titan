import Foundation

public enum ExecutablePath {
    /// The path a program was invoked through, without resolving symlinks: an absolute or
    /// relative argv[0] as given, else the first match on PATH, else `fallback`.
    public static func stable(argv0: String, path: String, fallback: String,
                              cwd: String = FileManager.default.currentDirectoryPath) -> String {
        let fm = FileManager.default
        if argv0.contains("/") {
            return URL(fileURLWithPath: argv0, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
        }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(argv0)"
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate).standardizedFileURL.path }
        }
        return fallback
    }
}
