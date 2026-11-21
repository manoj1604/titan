import Foundation

/// Runs a coding agent (Claude Code, Codex) **inside** the project's VM: it can only touch this
/// project's folder and its VM, so "no permission prompts" modes are reasonable there.
///
/// The agent's program and login live in `~/.titan/agents` on the Mac, mounted into every VM at
/// `/titan-agents`, so you install and log in once for all projects. Everything else (HOME,
/// caches, git config) stays per VM. VMs created before this existed keep them in the VM.
public enum CodingAgent: String, CaseIterable, Sendable {
    case claude, codex

    public static let guestDirectory = "/titan-agents"

    public var displayName: String { self == .claude ? "Claude Code" : "Codex" }

    /// The agent's flag for running without permission prompts.
    public var autoFlag: String {
        self == .claude ? "--dangerously-skip-permissions" : "--dangerously-bypass-approvals-and-sandbox"
    }

    /// Mac variables passed through when set (an API key instead of logging in).
    public var passthroughVariables: [String] {
        self == .claude ? ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"]
                        : ["OPENAI_API_KEY", "OPENAI_BASE_URL"]
    }

    /// Sets A (the agents folder: shared, or per-VM in older VMs), B (the program) and C (its
    /// config/login folder). POSIX sh; shared by the install step and the session.
    public var locateScript: String {
        let common = #"A=/titan-agents; [ -d "$A" ] || A=/root/.titan-agents"#
        switch self {
        case .claude:
            return common + #"; libc=gnu; if ldd --version 2>&1 | grep -qi musl; then libc=musl; fi; H="$A/claude-$libc"; B="$H/.local/bin/claude"; C="$A/claude""#
        case .codex:
            return common + #"; B="$A/bin/codex"; C="$A/codex""#
        }
    }

    /// Run as root before the session: makes sure curl/wget exist and installs the agent if it's
    /// missing (or with `update`). Progress goes to stderr.
    public func installScript(update: Bool) -> String {
        var lines = ["set -e", locateScript,
            #"[ "$A" = /titan-agents ] || echo "titan: this VM predates shared agent logins, so the login stays in this VM (\`titan rebuild\` shares it across projects)." >&2"#,
            #"mkdir -p "$A" "$C" && chmod a+rwx "$C" 2>/dev/null || true"#,
            #"if [ -x "$B" ] && [ -z "\#(update ? "1" : "")" ]; then exit 0; fi"#,
            #"""
            if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
              echo "titan: installing curl in the VM…" >&2
              if command -v apt-get >/dev/null 2>&1; then apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates >/dev/null
              elif command -v apk >/dev/null 2>&1; then apk add -q curl ca-certificates
              elif command -v dnf >/dev/null 2>&1; then dnf install -y -q curl
              else echo "titan: this VM has neither curl nor wget; add one to the image." >&2; exit 1; fi
            fi
            dl() { if command -v curl >/dev/null 2>&1; then curl -fsSL "$1"; else wget -qO- "$1"; fi; }
            """#,
            "echo \"titan: installing \(displayName) (once for all projects)…\" >&2",
        ]
        switch self {
        case .claude:
            lines.append(#"mkdir -p "$H" && dl https://claude.ai/install.sh | HOME="$H" bash >&2"#)
        case .codex:
            lines.append(#"""
            t=codex-aarch64-unknown-linux-musl
            mkdir -p "$A/bin" && dl "https://github.com/openai/codex/releases/latest/download/$t.tar.gz" | tar -xz -C "$A/bin"
            mv -f "$A/bin/$t" "$B" && chmod +x "$B"
            """#)
        }
        lines.append(#"[ -x "$B" ] || { echo "titan: the install didn't produce $B" >&2; exit 1; }"#)
        return lines.joined(separator: "\n")
    }

    /// The session: `sh -c '<locate>; export …; exec "$B" [auto flag] "$@"' titan-agent <args>`.
    public func sessionCommand(arguments: [String], auto: Bool) -> [String] {
        let export = self == .claude ? #"export CLAUDE_CONFIG_DIR="$C""# : #"export CODEX_HOME="$C""#
        let flag = auto ? " \(autoFlag)" : ""
        return ["/bin/sh", "-c", locateScript + "; " + export + #"; exec "$B""# + flag + #" "$@""#, "titan-agent"] + arguments
    }

    /// Extra variables: API keys from the Mac (when set) and agent settings.
    public func sessionEnvironment(auto: Bool, runsAsRoot: Bool, mac: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        for key in passthroughVariables { if let v = mac[key], !v.isEmpty { env[key] = v } }
        if self == .claude {
            env["DISABLE_AUTOUPDATER"] = "1"   // `titan agent claude --update` updates the shared copy
            // Claude Code refuses to skip permissions as root unless it's in a sandbox; the VM is one.
            if auto && runsAsRoot { env["IS_SANDBOX"] = "1" }
        }
        return env
    }
}
