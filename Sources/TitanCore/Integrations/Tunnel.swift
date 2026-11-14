import Foundation

/// Public HTTPS links to a project's forwarded port via Cloudflare quick tunnels
/// (`cloudflared tunnel --url`): no account, random *.trycloudflare.com hostname,
/// gone when the process exits.
public enum Tunnel {
    public static let binary = "cloudflared"
    public static let installHint = "brew install cloudflared"

    /// Chooses which forward to share. `requested` is the port as the app knows it
    /// (the VM side); a host-side port number is accepted too.
    public static func pick(_ requested: Int?, from ports: [PortMapping]) throws -> PortMapping {
        guard !ports.isEmpty else {
            throw TitanError.message("This project forwards no ports. Add one to forwardPorts in devcontainer.json "
                                     + "(or run `titan init` and edit it), then `titan up`.")
        }
        guard let requested else { return ports[0] }
        if let m = ports.first(where: { $0.guest == requested }) ?? ports.first(where: { $0.host == requested }) { return m }
        let list = ports.map(\.description).joined(separator: ", ")
        throw TitanError.message("Port \(requested) isn't forwarded by this project (forwarded: \(list)).")
    }

    /// `cloudflared` arguments. Rewriting the Host header to localhost keeps dev servers
    /// with host checks (Vite, webpack, Rails) from rejecting the tunnel's hostname.
    public static func arguments(for mapping: PortMapping, rewriteHost: Bool) -> [String] {
        var args = [binary, "tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(mapping.host)"]
        if rewriteHost { args += ["--http-host-header", "localhost:\(mapping.guest)"] }
        return args
    }

    /// The public URL from a line of cloudflared's log output, if it has one.
    public static func publicURL(in line: String) -> String? {
        guard let m = line.firstMatch(of: /https:\/\/[a-z0-9-]+\.trycloudflare\.com/) else { return nil }
        let url = String(m.output)
        return url == "https://api.trycloudflare.com" ? nil : url
    }

    /// Command that exits 0 when something in the VM listens on `port`. The Mac-side
    /// forwarder accepts connections even when the app is down, so check from inside;
    /// /proc/net/tcp needs no tools in the image (state 0A = LISTEN).
    public static func listenProbe(_ port: Int) -> [String] {
        let hex = String(format: "%04X", port)
        return ["/bin/sh", "-c", "grep -qiE ':\(hex) [0-9A-F]+:0000 0A' /proc/net/tcp /proc/net/tcp6 2>/dev/null"]
    }
}
