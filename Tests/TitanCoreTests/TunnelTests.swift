import Foundation
import Testing
@testable import TitanCore

@Suite struct TunnelTests {
    @Test func picksTheRightForward() throws {
        let ports = [PortMapping(host: 3001, guest: 3000), .same(5432)]
        #expect(try Tunnel.pick(nil, from: ports) == ports[0])
        #expect(try Tunnel.pick(3000, from: ports) == ports[0])   // the port the app knows
        #expect(try Tunnel.pick(3001, from: ports) == ports[0])   // the Mac-side port works too
        #expect(try Tunnel.pick(5432, from: ports) == ports[1])
        #expect(throws: TitanError.self) { try Tunnel.pick(9999, from: ports) }
        #expect(throws: TitanError.self) { try Tunnel.pick(nil, from: []) }
    }

    @Test func cloudflaredArguments() {
        let m = PortMapping(host: 3001, guest: 3000)
        #expect(Tunnel.arguments(for: m, rewriteHost: true) ==
                ["cloudflared", "tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:3001",
                 "--http-host-header", "localhost:3000"])
        #expect(!Tunnel.arguments(for: m, rewriteHost: false).contains("--http-host-header"))
    }

    @Test func findsThePublicURLInCloudflaredLogs() {
        let lines = [
            "2026-11-14T10:00:00Z INF Requesting new quick Tunnel on trycloudflare.com...",
            "2026-11-14T10:00:01Z INF |  https://quiet-river-1234-abc.trycloudflare.com                    |",
            "2026-11-14T10:00:00Z ERR failed to reach https://api.trycloudflare.com/tunnel",
        ]
        #expect(Tunnel.publicURL(in: lines[0]) == nil)
        #expect(Tunnel.publicURL(in: lines[1]) == "https://quiet-river-1234-abc.trycloudflare.com")
        #expect(Tunnel.publicURL(in: lines[2]) == nil)
    }

    @Test func listenProbeLooksForTheHexPortInListenState() {
        let cmd = Tunnel.listenProbe(3000).joined(separator: " ")
        #expect(cmd.contains(":0BB8 [0-9A-F]+:0000 0A"))
        #expect(cmd.contains("/proc/net/tcp6"))
    }
}
