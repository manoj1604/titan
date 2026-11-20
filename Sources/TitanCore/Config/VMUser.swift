import Foundation

/// The Linux user commands run as inside a VM. By default that's root (the image default).
///
/// Opt-in: `customizations.titan.user: "me"` creates a user named after you, with your Mac
/// uid, passwordless sudo, and a prompt like `manoj@shop:/workspaces/shop$`. The Dev Container
/// `remoteUser` (a user that already exists in the image) is honored too.
public struct VMUser: Equatable, Sendable {
    /// The config value meaning "a user named after the Mac user".
    public static let me = "me"

    public var name: String
    /// Set when Titan creates the user (the "me" case); nil for a user that already exists in the image.
    public var uid: Int?
    public var home: String?

    /// nil/"root" → nil (image default); anything else is kept.
    public static func normalize(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty, v != "root" else { return nil }
        return v
    }

    /// Resolves a config value to a concrete user, or nil for root.
    public static func resolve(_ value: String?, macUser: String = NSUserName(), uid: Int = Int(getuid())) -> VMUser? {
        guard let v = normalize(value) else { return nil }
        if v == me {
            let name = linuxName(from: macUser)
            return VMUser(name: name, uid: uid, home: "/home/\(name)")
        }
        return VMUser(name: v, uid: nil, home: nil)
    }

    /// A valid Linux username from the Mac one ("Manoj.Sahu" → "manoj-sahu"); names that clash
    /// with system or image users become "dev".
    static func linuxName(from mac: String) -> String {
        var name = mac.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        while name.hasPrefix("-") || name.first?.isNumber == true { name.removeFirst() }
        name = String(name.prefix(32))
        let reserved: Set<String> = ["root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news",
                                     "uucp", "proxy", "www-data", "backup", "list", "irc", "nobody", "node",
                                     "postgres", "redis", "_apt", "systemd-network", "messagebus"]
        return name.isEmpty || reserved.contains(name) ? "dev" : name
    }

    /// One-time setup, run as root in a fresh VM: create the user (if Titan owns it), passwordless
    /// sudo, ownership of /usr/local so global installs (`npm i -g`, `pip install`, cargo) work
    /// without sudo, and a prompt showing the project name (the VM's hostname can't be changed).
    public func setupScript(project: String) -> String {
        let prompt = project.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        var lines = ["set -e"]
        if let uid {
            lines.append("""
            if ! id -u \(name) >/dev/null 2>&1; then \
            if command -v useradd >/dev/null 2>&1; then \
            if getent passwd \(uid) >/dev/null 2>&1; then useradd -m -U -s /bin/bash \(name); \
            else useradd -m -U -u \(uid) -s /bin/bash \(name) 2>/dev/null; fi; \
            else adduser -D -u \(uid) -s /bin/sh \(name); fi; fi
            """)
            lines.append("mkdir -p /etc/sudoers.d && echo '\(name) ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/titan && chmod 440 /etc/sudoers.d/titan")
            lines.append("chown -R \(name): /usr/local 2>/dev/null || true")
            lines.append("[ -d /go ] && chown -R \(name): /go 2>/dev/null || true")
        }
        let home = self.home ?? "$(getent passwd \(name) | cut -d: -f6)"
        // printf with a double-quoted argument: "\\u" reaches the file as \u, giving PS1='\u@shop:\w\$ '.
        lines.append("h=\(home); if [ -d \"$h\" ]; then printf '%s\\n' '' '# Titan: show the project in the prompt' \"PS1='\\\\u@\(prompt):\\\\w\\\\$ '\" >> \"$h/.bashrc\"; chown \(name): \"$h/.bashrc\" 2>/dev/null || true; fi")
        lines.append("printf '%s\\n' '' '# Titan: show the project in the prompt' \"PS1='\\\\u@\(prompt):\\\\w# '\" >> /root/.bashrc")
        return lines.joined(separator: "\n")
    }

    /// Installs sudo in the background if the image lacks it (apt only; takes ~15 s, so it
    /// mustn't hold up `up`). `titan shell --root` works meanwhile.
    public static let sudoInstallScript =
        "command -v sudo >/dev/null 2>&1 || { command -v apt-get >/dev/null 2>&1 && "
        + "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo; } "
        + ">/tmp/titan-sudo.log 2>&1"
}
