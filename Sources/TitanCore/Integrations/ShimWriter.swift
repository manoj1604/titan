import Foundation

/// Writes .titan/bin/<cmd> scripts. With the shell hook active, `.titan/bin` is
/// first on PATH inside the project, so typing `npm test` runs in the VM.
public enum ShimWriter {
    static let marker = "# titan-shim"

    public static func write(project: Project, commands: [String], titan: String) throws {
        let fm = FileManager.default
        try Persistence.ensureStateDir(project)
        try fm.createDirectory(at: project.shimDir, withIntermediateDirectories: true)

        // Remove shims we previously generated that are no longer wanted.
        for file in (try? fm.contentsOfDirectory(atPath: project.shimDir.path)) ?? [] where !commands.contains(file) {
            let url = project.shimDir.appendingPathComponent(file)
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(marker) {
                try fm.removeItem(at: url)
            }
        }
        for cmd in commands where isSafeName(cmd) {
            let url = project.shimDir.appendingPathComponent(cmd)
            try Data(script(command: cmd, project: project, titan: titan).utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && s.allSatisfy { $0.isLetter || $0.isNumber || "-_.+".contains($0) }
    }

    public static func script(command: String, project: Project, titan: String) -> String {
        """
        #!/bin/sh
        \(marker): runs `\(command)` inside this project's Titan VM.
        # Set TITAN_DISABLE=1 to fall through to the host's \(command).
        if [ -n "${TITAN_DISABLE:-}" ]; then
          _titan_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
          PATH=$(printf '%s' "$PATH" | tr ':' '\\n' | grep -vxF "$_titan_dir" | paste -sd: -)
          export PATH
          exec \(shellQuote(command)) "$@"
        fi
        exec \(shellQuote(titan)) run -C \(shellQuote(project.root.path)) --shim -- \(shellQuote(command)) "$@"

        """
    }
}
