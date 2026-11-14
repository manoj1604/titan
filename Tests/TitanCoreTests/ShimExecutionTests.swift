import Foundation
import Testing
@testable import TitanCore

@Suite struct ShimExecutionTests {
    /// Runs a generated shim with TITAN_DISABLE=1 and checks it reaches the host binary,
    /// not itself (which would loop forever).
    @Test func disableFallsThroughToHostBinary() throws {
        let t = try TempProject()
        try ShimWriter.write(project: t.project, commands: ["echo"], titan: "/nonexistent/titan")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let shim = t.project.shimDir.appendingPathComponent("echo").path
        var env = ProcessInfo.processInfo.environment
        env["TITAN_DISABLE"] = "1"
        env["PATH"] = t.project.shimDir.path + ":/usr/bin:/bin"
        p.environment = env
        p.arguments = [shim, "hello", "from host"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "hello from host\n")
    }

    @Test func staleShimsAreRemovedButUserFilesKept() throws {
        let t = try TempProject()
        try ShimWriter.write(project: t.project, commands: ["node", "npm"], titan: "/x")
        try Data("#!/bin/sh\necho mine\n".utf8).write(to: t.project.shimDir.appendingPathComponent("custom"))
        try ShimWriter.write(project: t.project, commands: ["node"], titan: "/x")
        let files = try FileManager.default.contentsOfDirectory(atPath: t.project.shimDir.path).sorted()
        #expect(files == ["custom", "node"])
    }
}
