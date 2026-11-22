import Foundation

/// A short "Dev environment" section for coding agents in AGENTS.md (read by Codex, Cursor and
/// most agents), linked from CLAUDE.md (`@AGENTS.md`, Claude Code's import syntax). It tells
/// agents that commands run in the project's VM, how to reach services, and what not to do.
/// Only the fenced block is Titan's; the rest of the files stays the user's.
public enum AgentNotes {
    public static let begin = "<!-- titan:begin (written by Titan; `titan up` keeps it current) -->"
    public static let end = "<!-- titan:end -->"
    static let beginPrefix = "<!-- titan:begin"

    public static func agentsFile(_ project: Project) -> URL { project.root.appendingPathComponent("AGENTS.md") }
    public static func claudeFile(_ project: Project) -> URL { project.root.appendingPathComponent("CLAUDE.md") }

    public static func block(projectName: String, env: ResolvedEnvironment, ports: [PortMapping]) -> String {
        var lines = [
            begin,
            "## Dev environment (Titan)",
            "",
            "This project runs in its own Linux VM, managed by [Titan](https://github.com/manoj1604/titan).",
            "Files stay on the Mac and are shared live with the VM at `\(env.workspaceFolder)`.",
            "",
            "- **Run commands as usual** (`\(exampleCommand(env))`…): in this folder they run in the VM.",
            "  `titan run -- <command>` always runs in the VM, from any shell, if in doubt.",
            "- **Don't install runtimes or packages on the Mac** (no `brew install`, no global `npm -g`/`pip install`",
            "  outside the VM). Add dependencies the normal way (`npm install x`, `pip install x`), which runs in the VM,",
            "  and system packages or tools in `.devcontainer/devcontainer.json` (then `titan up --rebuild`).",
        ]
        if !ports.isEmpty {
            let list = ports.map { $0.host == $0.guest ? "\($0.guest)" : "\($0.guest) (on the Mac: \($0.host))" }
            lines.append("- **Ports:** the app listens on \(list.joined(separator: ", ")) in the VM; open http://localhost:\(ports[0].host) on the Mac.")
        }
        let services = env.serviceList
        if !services.isEmpty {
            let list = services.map { s in "`\(s.name)`" + (s.port.map { " (port \($0))" } ?? "") }
            let vars = services.flatMap { $0.appEnv.keys }.sorted()
            lines.append("- **Services:** \(list.joined(separator: ", ")), each in its own VM, reached by that name as the host"
                         + (vars.isEmpty ? "." : "; connection strings are in \(vars.map { "`$\($0)`" }.joined(separator: ", ")) inside the VM."))
            lines.append("  Logs: `titan logs <service>`.")
        }
        lines += [
            "- **Useful:** `titan status` (VM, ports, services) · `titan logs <service>` · `titan share <port>` (public link).",
            "- Don't run `titan down --volumes` or `titan gc` unless asked: they delete data.",
            end,
        ]
        return lines.joined(separator: "\n")
    }

    static func exampleCommand(_ env: ResolvedEnvironment) -> String {
        if env.shims.contains("npm") { return "npm test" }
        if env.shims.contains("python") || env.shims.contains("python3") { return "python -m pytest" }
        if env.shims.contains("go") { return "go test ./..." }
        if env.shims.contains("cargo") { return "cargo test" }
        if env.shims.contains("bundle") { return "bundle exec rspec" }
        return env.shims.first.map { "\($0) …" } ?? "make test"
    }

    public static func hasBlock(_ project: Project) -> Bool {
        ((try? String(contentsOf: agentsFile(project), encoding: .utf8)) ?? "").contains(beginPrefix)
    }

    /// Writes or refreshes the block, and links it from CLAUDE.md. Returns the files changed.
    @discardableResult
    public static func write(project: Project, env: ResolvedEnvironment, ports: [PortMapping]) throws -> [URL] {
        var changed: [URL] = []
        let agents = agentsFile(project)
        let text = (try? String(contentsOf: agents, encoding: .utf8)) ?? ""
        let blk = block(projectName: project.name, env: env, ports: ports)
        var updated: String
        if let s = text.range(of: beginPrefix), let e = text.range(of: end, range: s.upperBound..<text.endIndex) {
            updated = text.replacingCharacters(in: s.lowerBound..<e.upperBound, with: blk)
        } else if text.isEmpty {
            updated = "# AGENTS.md\n\n" + blk + "\n"
        } else {
            updated = text + (text.hasSuffix("\n") ? "" : "\n") + "\n" + blk + "\n"
        }
        if updated != text {
            try Data(updated.utf8).write(to: agents, options: .atomic)
            changed.append(agents)
        }
        let claude = claudeFile(project)
        let ctext = (try? String(contentsOf: claude, encoding: .utf8)) ?? ""
        if !ctext.contains("AGENTS.md") {
            let c = ctext.isEmpty ? "@AGENTS.md\n" : ctext + (ctext.hasSuffix("\n") ? "" : "\n") + "\n@AGENTS.md\n"
            try Data(c.utf8).write(to: claude, options: .atomic)
            changed.append(claude)
        }
        return changed
    }

    /// Keeps an existing block accurate (ports, services) without ever adding one.
    @discardableResult
    public static func refreshIfPresent(project: Project, env: ResolvedEnvironment, ports: [PortMapping]) -> Bool {
        guard hasBlock(project) else { return false }
        return !((try? write(project: project, env: env, ports: ports)) ?? []).isEmpty
    }

    /// Removes the block (and AGENTS.md / the CLAUDE.md link if nothing else is left).
    public static func remove(_ project: Project) throws {
        let agents = agentsFile(project)
        if let text = try? String(contentsOf: agents, encoding: .utf8),
           let s = text.range(of: beginPrefix), let e = text.range(of: end, range: s.upperBound..<text.endIndex) {
            let rest = text.replacingCharacters(in: s.lowerBound..<e.upperBound, with: "")
            let trimmed = rest.replacingOccurrences(of: "# AGENTS.md", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { try FileManager.default.removeItem(at: agents) }
            else { try Data((rest.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8).write(to: agents, options: .atomic) }
        }
        let claude = claudeFile(project)
        if !FileManager.default.fileExists(atPath: agents.path), let c = try? String(contentsOf: claude, encoding: .utf8) {
            let rest = c.replacingOccurrences(of: "@AGENTS.md", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.isEmpty { try FileManager.default.removeItem(at: claude) }
            else { try Data((rest + "\n").utf8).write(to: claude, options: .atomic) }
        }
    }
}
