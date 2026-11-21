import Foundation

/// Makes project commands run in their VM from **every** shell, not just interactive
/// terminals: coding agents (Claude Code, Codex, Cursor), scripts, Makefiles, cron.
///
/// The shell hook switches PATH on `cd`, which only interactive shells do. Global shims
/// decide when they run instead: `~/.titan/shims/npm` walks up from the current folder;
/// inside a Titan project it runs the project's shim (→ the VM), anywhere else the Mac's npm.
/// The folder goes first on PATH via `~/.zshenv` (every zsh) and `~/.zprofile` (login shells,
/// after macOS's path_helper reorders PATH), or the bash profile.
public enum GlobalShims {
    static let marker = "# titan-global-shim"
    public static let beginMarker = "# >>> titan shims >>>"
    public static let endMarker = "# <<< titan shims <<<"

    /// Adds a global shim for each command (never removes: another project may use it).
    public static func ensure(commands: [String], in dir: URL, titan: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for cmd in commands where ShimWriter.isSafeName(cmd) {
            let url = dir.appendingPathComponent(cmd)
            let text = script(command: cmd, dir: dir.path, titan: titan)
            if (try? String(contentsOf: url, encoding: .utf8)) == text { continue }
            if fm.fileExists(atPath: url.path), let old = try? String(contentsOf: url, encoding: .utf8), !old.contains(marker) {
                continue   // not ours: leave it alone
            }
            try Data(text.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    public static func script(command: String, dir: String, titan: String) -> String {
        let c = shellQuote(command)
        return """
        #!/bin/sh
        \(marker): runs `\(command)` in the Titan VM of the project you're in, else your Mac's.
        # Set TITAN_DISABLE=1 to always use the Mac's \(command).
        if [ -z "${TITAN_DISABLE:-}" ]; then
          d=$PWD
          while [ -n "$d" ]; do
            if [ -x "$d/.titan/bin/"\(c) ]; then exec "$d/.titan/bin/"\(c) "$@"; fi
            if [ -d "$d/.titan/bin" ]; then break; fi
            if [ -f "$d/titan.lock" ] || [ -f "$d/.devcontainer/devcontainer.json" ] || [ -f "$d/.devcontainer.json" ]; then
              # A fresh clone: set up its commands (doesn't start the VM), then try again.
              if \(shellQuote(titan)) activate -C "$d" --quiet >/dev/null 2>&1 && [ -x "$d/.titan/bin/"\(c) ]; then
                exec "$d/.titan/bin/"\(c) "$@"
              fi
              break
            fi
            [ "$d" = "$HOME" ] && break
            d=${d%/*}
          done
        fi
        PATH=$(printf '%s' "$PATH" | tr ':' '\\n' | grep -vxF \(shellQuote(dir)) | paste -sd: -)
        export PATH
        exec \(c) "$@"

        """
    }

    /// Puts the shims folder first on PATH (moving it there if path_helper pushed it back).
    /// Valid in zsh, bash and sh; no subprocesses.
    public static func pathBlock(dir: String) -> String {
        let d = dir.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME")
        return """
        \(beginMarker)
        # Lets every shell (coding agents and scripts too) run project commands in their Titan VM.
        _titan_shims="\(d)"
        if [ -d "$_titan_shims" ]; then
          PATH=":$PATH:"; PATH="${PATH//:$_titan_shims:/:}"; PATH="${PATH#:}"; PATH="${PATH%:}"
          export PATH="$_titan_shims${PATH:+:$PATH}"
        fi
        unset _titan_shims
        \(endMarker)
        """
    }

    /// Startup files that need the block: every zsh reads .zshenv; login shells (Codex's
    /// `zsh -lc`) run path_helper after it, so .zprofile repeats it; bash reads its login profile.
    /// Both shells regardless of the user's own: agents and tools often run `bash -lc` explicitly.
    public static func startupFiles(shell: String, home: URL) -> [URL] {
        let profile = home.appendingPathComponent(".bash_profile")
        let bash = FileManager.default.fileExists(atPath: profile.path) ? profile : home.appendingPathComponent(".profile")
        return [home.appendingPathComponent(".zshenv"), home.appendingPathComponent(".zprofile"), bash]
    }

    /// Adds (or refreshes) the block at the end of each file. Returns the files changed.
    @discardableResult
    public static func installPath(shell: String, home: URL, dir: String) throws -> [URL] {
        var changed: [URL] = []
        let block = pathBlock(dir: dir)
        for file in startupFiles(shell: shell, home: home) {
            let url = file.resolvingSymlinksInPath()
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var updated: String
            if let start = text.range(of: beginMarker), let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) {
                updated = text.replacingCharacters(in: start.lowerBound..<end.upperBound, with: block)
            } else {
                updated = text
                if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
                updated += (updated.isEmpty ? "" : "\n") + block + "\n"
            }
            guard updated != text else { continue }
            try Data(updated.utf8).write(to: url, options: .atomic)
            changed.append(file)
        }
        return changed
    }

    public static func isInstalled(shell: String, home: URL) -> Bool {
        startupFiles(shell: shell, home: home).allSatisfy {
            ((try? String(contentsOf: $0.resolvingSymlinksInPath(), encoding: .utf8)) ?? "").contains(beginMarker)
        }
    }
}
