import Foundation

/// Adds (or finds) the Titan shell hook in the user's shell startup file.
/// The block is fenced with markers so it's easy to spot, update, or remove.
public enum ShellSetup {
    public static let beginMarker = "# >>> titan >>>"
    public static let endMarker = "# <<< titan <<<"

    /// zsh → ~/.zshrc. bash → ~/.bash_profile when it exists (macOS opens login shells),
    /// else ~/.bashrc.
    public static func rcFile(shell: String, home: URL) -> URL {
        if shell == "bash" {
            let profile = home.appendingPathComponent(".bash_profile")
            return FileManager.default.fileExists(atPath: profile.path) ? profile : home.appendingPathComponent(".bashrc")
        }
        return home.appendingPathComponent(".zshrc")
    }

    /// The hook line uses titan's absolute path, so it works even when titan's folder
    /// isn't on PATH (the hook then also provides the `titan` command itself).
    public static func block(shell: String, titan: String) -> String {
        """
        \(beginMarker)
        # Runs project commands inside their Titan VM. Remove this block to uninstall.
        [ -x \(shellQuote(titan)) ] && eval "$(\(shellQuote(titan)) hook \(shell))"
        \(endMarker)
        """
    }

    public enum State: Equatable { case missing, installed, managedBlock }

    /// Set when the user said no to the hook in `titan setup` (older Titan); automatic installs respect it.
    public static func declinedMarker(_ paths: TitanPaths = .standard) -> URL {
        paths.support.appendingPathComponent("no-shell-hook")
    }

    public enum AutoResult: Equatable { case added(URL), alreadyThere, skipped }

    /// Adds the hook behind the scenes (from `titan create/up`) when it's missing, unless the
    /// user declined it, opted out (TITAN_NO_SHELL_HOOK), or uses an unsupported shell.
    public static func ensureInstalled(shell: String, home: URL, titan: String, paths: TitanPaths = .standard,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) -> AutoResult {
        guard environment["TITAN_NO_SHELL_HOOK"] == nil, environment["TITAN_HOOK"] == nil,
              ShellHook.script(for: shell) != nil,
              !FileManager.default.fileExists(atPath: declinedMarker(paths).path) else { return .skipped }
        let rc = rcFile(shell: shell, home: home)
        let text = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
        guard state(of: text) == .missing else { return .alreadyThere }
        return (try? install(into: rc, shell: shell, titan: titan)) == true ? .added(rc) : .skipped
    }

    /// `installed`: some titan hook line exists (maybe hand-written); `managedBlock`: ours.
    public static func state(of text: String) -> State {
        if text.contains(beginMarker) { return .managedBlock }
        let active = text.split(separator: "\n").contains { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return !l.hasPrefix("#") && l.contains("titan") && l.contains(" hook ")
        }
        return active ? .installed : .missing
    }

    /// Adds the block (or refreshes our own block, e.g. after titan moved). Returns true if
    /// the file changed. Never touches a hand-written hook line.
    @discardableResult
    public static func install(into rc: URL, shell: String, titan: String) throws -> Bool {
        // Dotfile managers often symlink ~/.zshrc; write the real file, keep the link.
        let url = rc.resolvingSymlinksInPath()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let block = block(shell: shell, titan: titan)
        var updated: String
        switch state(of: text) {
        case .installed:
            return false
        case .managedBlock:
            guard let start = text.range(of: beginMarker), let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) else {
                return false
            }
            updated = text.replacingCharacters(in: start.lowerBound..<end.upperBound, with: block)
        case .missing:
            updated = text
            if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
            updated += (updated.isEmpty ? "" : "\n") + block + "\n"
        }
        guard updated != text else { return false }
        try Data(updated.utf8).write(to: url, options: .atomic)
        return true
    }
}
