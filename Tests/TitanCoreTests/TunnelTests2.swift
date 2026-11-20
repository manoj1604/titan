import Foundation
import Testing
@testable import TitanCore

@Suite struct TunnelPlanTests {
    @Test func durations() {
        #expect(TunnelPlan.parseDuration("90") == 90 && TunnelPlan.parseDuration("90s") == 90)
        #expect(TunnelPlan.parseDuration("30m") == 1800 && TunnelPlan.parseDuration("2h") == 7200 && TunnelPlan.parseDuration("1d") == 86400)
        #expect(TunnelPlan.parseDuration("0m") == nil && TunnelPlan.parseDuration("soon") == nil)
        #expect(TunnelPlan.describe(seconds: 7200) == "2h" && TunnelPlan.describe(seconds: 90) == "90s")
    }

    @Test func passwordsAreReadable() {
        let pw = TunnelPlan.generatePassword()
        #expect(pw.wholeMatch(of: /[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}/) != nil)
        #expect(!pw.contains("0") && !pw.contains("1") && !pw.contains("l") && !pw.contains("o"))
        #expect(TunnelPlan.generatePassword() != pw)
    }

    @Test func domains() {
        #expect(TunnelPlan.isValidDomain("dev.example.com") && TunnelPlan.isValidDomain("a-b.c.example.co"))
        #expect(!TunnelPlan.isValidDomain("example") && !TunnelPlan.isValidDomain("-bad.example.com") && !TunnelPlan.isValidDomain("dev example.com"))
        #expect(TunnelPlan.tunnelName(for: "dev.example.com") == "titan-dev-example-com")
    }

    let spec = TunnelSpec(projectRoot: "/p", projectName: "shop", containerName: "titan-shop-1", guestPort: 5173, hostPort: 5174)

    @Test func cloudflaredArguments() {
        #expect(TunnelPlan.cloudflaredArguments(spec: spec, target: "http://127.0.0.1:9000", rewriteHostWithoutGate: false)
                == ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:9000"])
        #expect(TunnelPlan.cloudflaredArguments(spec: spec, target: "http://127.0.0.1:5174", rewriteHostWithoutGate: true).suffix(2)
                == ["--http-host-header", "localhost:5173"])
        var named = spec; named.domain = "dev.example.com"
        #expect(TunnelPlan.cloudflaredArguments(spec: named, target: "http://127.0.0.1:9000", rewriteHostWithoutGate: false)
                == ["tunnel", "--no-autoupdate", "run", "--url", "http://127.0.0.1:9000", "titan-dev-example-com"])
    }

    @Test func gateArgumentsKeepThePasswordOutOfThem() {
        var s = spec; s.password = "secret-pw"
        let args = TunnelPlan.gateArguments(spec: s, visitLog: "/tmp/v.log")
        #expect(args == ["-upstream", "http://127.0.0.1:5174", "-name", "shop", "-log", "/tmp/v.log", "-host", "localhost:5173"])
        #expect(!args.contains("secret-pw"))
        s.keepHost = true
        #expect(!TunnelPlan.gateArguments(spec: s, visitLog: "x").contains("-host"))
    }

    @Test func connectedLine() {
        #expect(TunnelPlan.isConnected("2026-11-21T10:00:00Z INF Registered tunnel connection connIndex=0 location=bom01"))
        #expect(!TunnelPlan.isConnected("INF Starting tunnel"))
    }
}

@Suite struct TunnelStoreTests {
    @Test func savesListsAndPrunesDeadSupervisors() throws {
        let store = TunnelStore(paths: tempPaths())
        let spec = TunnelSpec(projectRoot: "/p", projectName: "shop", containerName: "titan-shop-1", guestPort: 5173, hostPort: 5173, password: "pw")
        try store.save(TunnelRecord(spec: spec, pid: getpid(), url: "https://x.trycloudflare.com", startedAt: Date(), expiresAt: nil, visitLog: "v"))
        var dead = spec; dead.guestPort = 8000
        try store.save(TunnelRecord(spec: dead, pid: 999_999, url: "https://y", startedAt: Date(), expiresAt: nil, visitLog: "v"))
        let live = store.list(alive: { $0 == getpid() })
        #expect(live.map(\.spec.guestPort) == [5173])
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("titan-shop-1-8000.json").path))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("titan-shop-1-5173.json").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)        // holds a password
    }

    @Test func domainChoicesAreRememberedPerProjectAndPort() throws {
        let paths = tempPaths()
        let p = Project(root: URL(fileURLWithPath: "/Users/me/code/shop"))
        var choices = DomainChoices()
        choices.set(p, port: 5173, .init(domain: "dev.example.com", always: true, password: nil))
        try choices.save(paths)
        #expect(DomainChoices.load(paths).choice(p, port: 5173)?.domain == "dev.example.com")
        choices.set(p, port: 5173, nil)
        #expect(choices.projects.isEmpty)
    }
}

/// A fake `cloudflared` that answers like the real one, for supervisor tests without the network.
final class FakeCloudflared: CommandRunner, @unchecked Sendable {
    var listJSON = "[]"
    var routeResult = CommandResult(status: 0, stdout: "Added CNAME", stderr: "")
    var calls: [[String]] = []
    func capture(_ args: [String]) throws -> CommandResult {
        calls.append(args)
        if args.contains("list") { return CommandResult(status: 0, stdout: listJSON, stderr: "") }
        if args.contains("route") { return routeResult }
        return CommandResult(status: 0, stdout: "Created tunnel", stderr: "")
    }
    func passthrough(_ args: [String]) throws -> Int32 { 0 }
    func replaceProcess(_ args: [String]) throws -> Never { fatalError() }
    func which(_ name: String) -> String? { "/usr/bin/true" }
}

@Suite struct NamedTunnelSetupTests {
    func home(loggedIn: Bool) throws -> URL {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: h.appendingPathComponent(".cloudflared"), withIntermediateDirectories: true)
        if loggedIn { try Data().write(to: h.appendingPathComponent(".cloudflared/cert.pem")) }
        return h
    }

    @Test func reusesAnExistingTunnelOrCreatesOne() throws {
        let fake = FakeCloudflared()
        let setup = NamedTunnelSetup(runner: fake, cloudflared: "cloudflared", home: try home(loggedIn: true))
        #expect(setup.isLoggedIn)
        fake.listJSON = #"[{"id":"abc","name":"titan-dev-example-com","deleted_at":"0001-01-01T00:00:00Z"}]"#
        #expect(try setup.ensureTunnel(for: "dev.example.com", console: Console(quiet: true)) == "titan-dev-example-com")
        #expect(!fake.calls.contains { $0.contains("create") })
        fake.listJSON = "[]"
        _ = try setup.ensureTunnel(for: "dev.example.com", console: Console(quiet: true))
        #expect(fake.calls.last == ["cloudflared", "tunnel", "create", "titan-dev-example-com"])
    }

    @Test func neverOverwritesAnExistingDNSRecord() throws {
        let fake = FakeCloudflared()
        fake.routeResult = CommandResult(status: 1, stdout: "", stderr: "Failed to add route: code: 1003, reason: An A, AAAA, or CNAME record with that host already exists.")
        let setup = NamedTunnelSetup(runner: fake, cloudflared: "cloudflared", home: try home(loggedIn: true))
        #expect(throws: TitanError.self) { try setup.routeDNS("www.example.com", to: "titan-www-example-com", console: Console(quiet: true)) }
        #expect(!fake.calls.contains { $0.contains("--overwrite-dns") })
        #expect(!NamedTunnelSetup(runner: fake, cloudflared: "c", home: try home(loggedIn: false)).isLoggedIn)
    }
}

@Suite struct TunnelSupervisorTests {
    /// A script standing in for cloudflared: prints what the real one prints, then waits.
    func fakeCloudflared(_ line: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-cf-\(UUID().uuidString)")
        try Data("#!/bin/sh\necho '2026-11-21T10:00:00Z INF \(line)' >&2\nexec sleep 30\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    let spec = TunnelSpec(projectRoot: "/p", projectName: "shop", containerName: "titan-shop-1", guestPort: 5173, hostPort: 5173)

    @Test func quickTunnelReportsItsLinkAndCleansUp() throws {
        let store = TunnelStore(paths: tempPaths())
        let sup = TunnelSupervisor(spec: spec, store: store,
                                   cloudflared: try fakeCloudflared("|  https://quiet-river-1234.trycloudflare.com  |"), gatePath: nil)
        #expect(try sup.start(timeout: 10) == "https://quiet-river-1234.trycloudflare.com")
        #expect(store.record(spec.id)?.url == "https://quiet-river-1234.trycloudflare.com")
        sup.stop()
        #expect(store.record(spec.id) == nil)
    }

    @Test func namedTunnelIsReadyOnceConnected() throws {
        var s = spec; s.domain = "dev.example.com"
        let store = TunnelStore(paths: tempPaths())
        let sup = TunnelSupervisor(spec: s, store: store,
                                   cloudflared: try fakeCloudflared("Registered tunnel connection connIndex=0 location=bom01"), gatePath: nil)
        #expect(try sup.start(timeout: 10) == "https://dev.example.com")
        sup.stop()
    }

    @Test func ttlClosesTheTunnel() throws {
        var s = spec; s.ttlSeconds = 1
        let store = TunnelStore(paths: tempPaths())
        let sup = TunnelSupervisor(spec: s, store: store, cloudflared: try fakeCloudflared("https://a-b.trycloudflare.com"), gatePath: nil)
        _ = try sup.start(timeout: 10)
        let began = Date()
        sup.runUntilStopped()                                       // returns on its own at the TTL
        #expect(Date().timeIntervalSince(began) < 5)
        #expect(store.record(s.id) == nil)
    }

    @Test func passwordWithoutTheGateIsRefused() {
        var s = spec; s.password = "x"
        let sup = TunnelSupervisor(spec: s, store: TunnelStore(paths: tempPaths()), cloudflared: "/usr/bin/true", gatePath: nil)
        #expect(throws: TitanError.self) { _ = try sup.start(timeout: 1) }
    }
}
