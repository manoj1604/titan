import Foundation
import Testing
@testable import TitanCore

/// Regression: 0.2.0's `titan shell` froze because Foundation's Process put the interactive
/// `container exec` in a new process group, so it wasn't in the terminal's foreground.
@Suite struct PassthroughTests {
    @Test func childStaysInTitansProcessGroup() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pgid-\(UUID().uuidString)")
        let code = try ProcessRunner().passthrough(["/bin/sh", "-c", "ps -o pgid= -p $$ > '\(out.path)'"])
        #expect(code == 0)
        let childGroup = try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(childGroup == String(getpgrp()))
    }

    @Test func exitCodesAndSignalsLikeAShell() throws {
        #expect(try ProcessRunner().passthrough(["/bin/sh", "-c", "exit 7"]) == 7)
        #expect(try ProcessRunner().passthrough(["/bin/sh", "-c", "kill -KILL $$"]) == 128 + SIGKILL)   // KILL: the runner may ignore TERM
        #expect(ProcessRunner.exitCode(fromWaitStatus: 3 << 8) == 3)
        #expect(ProcessRunner.exitCode(fromWaitStatus: SIGKILL) == 128 + SIGKILL)
    }
}
