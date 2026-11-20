import Foundation

/// Lets commands inside `titan shell` open things on the Mac: `code src/App.tsx` opens VS Code
/// on the Mac at that file, `open http://localhost:5173` opens the Mac's browser, and tools that
/// honour `$BROWSER` (vite --open, gh auth login) do the same.
///
/// The channel is a mailbox folder inside the project (`.titan/open/`), which the VM sees through
/// its workspace mount, so there's no network listener (no firewall prompt). Small helper scripts
/// in `.titan/vm-bin/` write a request; `titan shell` on the Mac watches the mailbox while the
/// session lasts, checks a per-session token, maps VM paths back to Mac paths, and runs the
/// editor directly (no shell). Only files inside the project and http(s) URLs are accepted.
public struct OpenBridge: Sendable {
    public struct Editor: Sendable, Equatable {
        public var cli: String
        public var app: String
    }

    /// VM command → the Mac editor it opens (CLI if installed, else the app via `open -a`).
    public static let editors: [String: Editor] = [
        "code": Editor(cli: "code", app: "Visual Studio Code"),
        "cursor": Editor(cli: "cursor", app: "Cursor"),
        "zed": Editor(cli: "zed", app: "Zed"),
        "subl": Editor(cli: "subl", app: "Sublime Text"),
    ]
    /// VM commands that open files or URLs with the Mac's default app.
    public static let openers = ["open", "xdg-open"]

    public let project: Project
    public let workspace: String
    public let token: String

    public init(project: Project, workspace: String, token: String = UUID().uuidString) {
        self.project = project
        self.workspace = workspace
        self.token = token
    }

    public var mailbox: URL { project.stateDir.appendingPathComponent("open") }
    public var helperDir: URL { project.stateDir.appendingPathComponent("vm-bin") }
    public var guestMailbox: String { workspace + "/.titan/open" }
    public var guestHelperDir: String { workspace + "/.titan/vm-bin" }

    /// Environment for the VM session.
    public var environment: [String: String] {
        ["TITAN_OPEN_DIR": guestMailbox, "TITAN_OPEN_TOKEN": token, "TITAN_VM_BIN": guestHelperDir,
         "BROWSER": guestHelperDir + "/xdg-open"]
    }

    /// Writes the helpers and an empty mailbox (stale requests from an old session are dropped).
    public func install() throws {
        let fm = FileManager.default
        try Persistence.ensureStateDir(project)
        try? fm.removeItem(at: mailbox)
        try fm.createDirectory(at: mailbox, withIntermediateDirectories: true)
        try fm.createDirectory(at: helperDir, withIntermediateDirectories: true)
        for name in Self.editors.keys.sorted() + Self.openers {
            let url = helperDir.appendingPathComponent(name)
            try Data(Self.helperScript(name: name).utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// POSIX sh helper: resolves relative paths against the VM's cwd, writes the request
    /// atomically (temp file + mv), and exits right away.
    public static func helperScript(name: String) -> String {
        """
        #!/bin/sh
        # titan: `\(name)` opens on your Mac (works inside `titan shell`).
        if [ -z "${TITAN_OPEN_DIR:-}" ] || [ ! -d "$TITAN_OPEN_DIR" ]; then
          echo "\(name): only works inside \\`titan shell\\` (it opens on your Mac)" >&2
          exit 1
        fi
        req="$TITAN_OPEN_DIR/.req.$$"
        {
          printf '%s\\n' "$TITAN_OPEN_TOKEN" "\(name)"
          for a in "$@"; do
            case "$a" in
              -*|http://*|https://*|/*) printf '%s\\n' "$a" ;;
              *) printf '%s\\n' "$PWD/$a" ;;
            esac
          done
        } > "$req" && mv "$req" "$TITAN_OPEN_DIR/req.$$.$(date +%s)"

        """
    }

    public struct Request: Equatable, Sendable {
        public var command: String
        public var arguments: [String]
    }

    /// Parses a request file; nil if it's malformed or from another session.
    public func parse(_ text: String) -> Request? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 2, lines[0] == token else { return nil }
        let command = lines[1]
        guard Self.editors[command] != nil || Self.openers.contains(command) else { return nil }
        return Request(command: command, arguments: Array(lines.dropFirst(2)))
    }

    /// What to run on the Mac (each an argv, run without a shell), plus messages for the user.
    public func plan(_ req: Request, which: (String) -> String?) -> (commands: [[String]], warnings: [String]) {
        var paths: [String] = []
        var flags: [String] = []
        var urls: [String] = []
        var warnings: [String] = []
        for arg in req.arguments {
            if arg.hasPrefix("http://") || arg.hasPrefix("https://") {
                urls.append(arg)
            } else if arg.hasPrefix("-") {
                flags.append(arg)
            } else if let host = hostPath(for: arg) {
                paths.append(host)
            } else {
                warnings.append("\(arg) is only inside the VM, so it can't open on the Mac (only files in the project can).")
            }
        }
        if let editor = Self.editors[req.command] {
            if !urls.isEmpty { warnings.append("\(req.command) opens files; use `open <url>` for links.") }
            let targets = paths.isEmpty && warnings.isEmpty ? [project.root.path] : paths  // bare `code` → the project
            guard !targets.isEmpty else { return ([], warnings) }
            if let cli = which(editor.cli) { return ([[cli] + flags + targets], warnings) }
            return ([["/usr/bin/open", "-a", editor.app] + targets], warnings)
        }
        return ((urls + paths).map { ["/usr/bin/open", $0] }, warnings)
    }

    /// `/workspaces/shop/src/App.tsx:12` → `<project>/src/App.tsx:12`; nil outside the project.
    func hostPath(for guest: String) -> String? {
        guard guest.hasPrefix("/") else { return nil }
        if guest == workspace { return project.root.path }
        let prefix = workspace.hasSuffix("/") ? workspace : workspace + "/"
        guard guest.hasPrefix(prefix) else { return nil }
        let rest = guest.dropFirst(prefix.count)
        // Refuse escapes like /workspaces/shop/../../etc.
        guard !rest.split(separator: "/").contains("..") else { return nil }
        return project.root.path + "/" + rest
    }

    /// Handles every waiting request once. `run` launches an argv; `warn` shows a message.
    public func drain(which: (String) -> String?, run: ([String]) -> Void, warn: (String) -> Void) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: mailbox.path) else { return }
        for name in names.sorted() where name.hasPrefix("req.") {
            let url = mailbox.appendingPathComponent(name)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? fm.removeItem(at: url)
            guard let req = parse(text) else { continue }
            let (commands, warnings) = plan(req, which: which)
            warnings.forEach(warn)
            commands.forEach(run)
        }
    }

    /// Removes the mailbox and helpers when the session ends.
    public func uninstall() {
        try? FileManager.default.removeItem(at: mailbox)
    }
}
