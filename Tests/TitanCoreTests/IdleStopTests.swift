import Foundation
import Testing
@testable import TitanCore

@Suite struct IdleStopTests {
    @Test func timeoutSetting() {
        #expect(IdleStop.timeout(config: nil, environment: [:]) == 7200)
        #expect(IdleStop.timeout(config: "30m", environment: [:]) == 1800)
        #expect(IdleStop.timeout(config: "off", environment: [:]) == nil)
        #expect(IdleStop.timeout(config: nil, environment: ["TITAN_IDLE_STOP": "never"]) == nil)
        #expect(IdleStop.timeout(config: nil, environment: ["TITAN_IDLE_STOP": "1h"]) == 3600)
        #expect(IdleStop.timeout(config: "45m", environment: ["TITAN_IDLE_STOP": "off"]) == 2700)  // project wins
        #expect(IdleStop.timeout(config: "soon", environment: [:]) == 7200)                       // unreadable → default
    }

    @Test func configAcceptsFalseOrDuration() throws {
        let off = try TempProject([".devcontainer.json": #"{"image":"node:22","customizations":{"titan":{"idleStop":false}}}"#])
        #expect(IdleStop.timeout(config: try EnvironmentResolver.resolve(off.project).idleStop, environment: [:]) == nil)
        let short = try TempProject([".devcontainer.json": #"{"image":"node:22","customizations":{"titan":{"idleStop":"20m"}}}"#])
        let env = try EnvironmentResolver.resolve(short.project)
        #expect(IdleStop.timeout(config: env.idleStop, environment: [:]) == 1200)
        // Changing it must not rebuild the VM.
        try Data(#"{"image":"node:22"}"#.utf8).write(to: short.project.root.appendingPathComponent(".devcontainer.json"))
        #expect(try EnvironmentResolver.resolve(short.project).configHash == env.configHash)
    }

    @Test func stopsOnlyAfterTheWholeTimeoutQuiet() {
        var t = IdleStop.Tracker(timeout: 600)
        let t0 = Date(timeIntervalSince1970: 0)
        let a = t.check(now: t0, sessions: 0, tunnels: 0, cpuUsec: 0, interval: 0)
        let b = t.check(now: t0 + 300, sessions: 0, tunnels: 0, cpuUsec: 1_000_000, interval: 300)   // 0.3% of a core: quiet
        let c = t.check(now: t0 + 600, sessions: 0, tunnels: 0, cpuUsec: 2_000_000, interval: 300)
        #expect(!a && !b && c)
    }

    @Test func anySignOfUseResetsTheClock() {
        let t0 = Date(timeIntervalSince1970: 0)
        for (s, tun, busy) in [(1, 0, false), (0, 1, false), (0, 0, true)] {
            var t = IdleStop.Tracker(timeout: 600)
            _ = t.check(now: t0, sessions: 0, tunnels: 0, cpuUsec: 0, interval: 0)
            let cpu: UInt64 = busy ? 60_000_000 : 0   // 60 s of CPU in 500 s = 12%
            let busyNow = t.check(now: t0 + 500, sessions: s, tunnels: tun, cpuUsec: cpu, interval: 500)
            #expect(!busyNow && t.idleSince == nil)
            let later = t.check(now: t0 + 1000, sessions: 0, tunnels: 0, cpuUsec: cpu, interval: 500)  // clock restarted
            #expect(!later)
        }
    }

    @Test func sessionsFollowLiveProcesses() throws {
        let t = try TempProject(["package.json": "{}"])
        IdleStop.markSession(t.project, pid: 111)
        IdleStop.markSession(t.project, pid: 222)
        #expect(IdleStop.activeSessions(t.project, alive: { $0 == 222 }) == [222])
        #expect(IdleStop.activeSessions(t.project, alive: { _ in true }) == [222])   // 111's file was pruned
        IdleStop.endSession(t.project, pid: 222)
        #expect(IdleStop.activeSessions(t.project, alive: { _ in true }).isEmpty)
    }

    @Test func stopNoteIsShownOnce() throws {
        let t = try TempProject(["package.json": "{}"])
        #expect(!IdleStop.takeStopNote(t.project))
        try IdleStop.recordStop(t.project)
        #expect(IdleStop.takeStopNote(t.project))
        #expect(!IdleStop.takeStopNote(t.project))
    }
}
