import Foundation
import Testing
@testable import TitanCore

@Suite struct NewProjectTests {
    let folder = URL(fileURLWithPath: "/tmp/shop")

    @Test func planUsesCatalogDefaultsAndMarksCachedImages() throws {
        let vite = try #require(ProjectTemplate.find("vite"))
        let local = [LocalImage(digest: "sha256:n", references: ["docker.io/library/node:22-bookworm"], sizeBytes: 1)]
        let plan = try NewProjectPlan.make(name: "shop", folder: folder, template: vite, runtimeVersion: nil,
                                           services: ["postgres"], localImages: local, useToolchainStore: false)
        #expect(plan.image == "node:22-bookworm")
        #expect(plan.items.map(\.cached) == [true, false])          // node cached, postgres to download
        #expect(plan.items[1].image == "postgres:16-bookworm")
        #expect(plan.neededBytes == UInt64(160 * 4) << 20)          // only what isn't cached
    }

    @Test func runtimeVersionOverride() throws {
        let t = try #require(ProjectTemplate.find("fastapi"))
        let plan = try NewProjectPlan.make(name: "api", folder: folder, template: t, runtimeVersion: "3.13", services: [], localImages: [])
        #expect(plan.toolchain == ToolchainRequest(kind: .python, version: "3.13"))   // store
        let full = try NewProjectPlan.make(name: "api", folder: folder, template: t, runtimeVersion: "3.13", services: [], localImages: [],
                                           useToolchainStore: false)
        #expect(full.image == "python:3.13-bookworm")
    }

    @Test func devcontainerIsStandardAndRoundTrips() throws {
        let t = try #require(ProjectTemplate.find("vite"))
        let plan = try NewProjectPlan.make(name: "shop", folder: folder, template: t, runtimeVersion: nil, services: ["redis"], localImages: [])
        let config = try DevContainerConfig.parse(plan.devcontainer())
        #expect(config.image == "buildpack-deps:bookworm" && config.forwardPorts == [5173])
        #expect(config.postCreateCommand == .shell("npm install"))
        #expect(config.titan?.services?.entries.map(\.name) == ["redis"])
    }

    @Test func generationRunsInScratchThenCopiesIn() throws {
        let t = try #require(ProjectTemplate.find("go"))
        let plan = try NewProjectPlan.make(name: "svc", folder: folder, template: t, runtimeVersion: nil, services: [], localImages: [])
        let script = plan.generationScript(workspace: "/workspaces/svc")
        #expect(script.hasPrefix("set -e; rm -rf /tmp/titan-new"))
        #expect(script.contains("go mod init svc"))
        #expect(script.hasSuffix("cp -R /tmp/titan-new/svc/. /workspaces/svc/ && rm -rf /tmp/titan-new"))
        #expect(script.contains("(cd svc && go mod init svc"))      // the shell stays in the scratch folder
        #expect(!script.contains("{name}") && !script.contains("{dir}"))
    }

    @Test func generatorsSeeALowercasePackageName() throws {
        let t = try #require(ProjectTemplate.find("vite"))
        let plan = try NewProjectPlan.make(name: "MyShop", folder: folder, template: t, runtimeVersion: nil, services: [], localImages: [])
        let script = plan.generationScript(workspace: "/workspaces/MyShop")
        #expect(script.contains("vite@latest myshop "))
        #expect(script.contains("cp -R /tmp/titan-new/myshop/. /workspaces/MyShop/"))
    }

    @Test func rejectsBadNames() {
        #expect(throws: TitanError.self) { try NewProjectPlan.validate(name: "my app") }
        #expect(throws: TitanError.self) { try NewProjectPlan.validate(name: "1shop") }
        #expect(throws: Never.self) { try NewProjectPlan.validate(name: "shop-api_2") }
    }

    @Test func everyTemplateIsComplete() {
        for t in ProjectTemplate.all {
            #expect(!t.generate.isEmpty && !t.shims.isEmpty && !t.devCommand.isEmpty, "template \(t.id)")
        }
    }

    @Test func bootstrapRunsAfterServicesAndBeforeInstall() throws {
        let t = try TempProject([".devcontainer.json": #"{"image":"node:22","postCreateCommand":"npm install","customizations":{"titan":{"services":["postgres"]}}}"#])
        let rt = FakeRuntime()
        try makeEngine(t.project, rt).up(bootstrap: [["/bin/sh", "-c", "generate-code"]])
        let gen = try #require(rt.execs.firstIndex { $0.command.last == "generate-code" })
        let install = try #require(rt.execs.firstIndex { $0.command.last == "npm install" })
        let hosts = try #require(rt.execs.firstIndex { $0.command.last?.contains("titan-service") == true })
        #expect(hosts < gen && gen < install)
        // Bootstrap is for creation only: a second `up` doesn't regenerate.
        rt.execs = []
        try makeEngine(t.project, rt).up(bootstrap: [["/bin/sh", "-c", "generate-code"]])
        #expect(!rt.execs.contains { $0.command.last == "generate-code" })
    }
}

@Suite struct CdWrapperTests {
    @Test(arguments: ["zsh", "bash"])
    func titanNewMovesTheShellIntoTheProject(shell: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cd-\(UUID().uuidString)").resolvingSymlinksInPath()
        let target = root.appendingPathComponent("shop")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("fake-titan")
        try Data("#!/bin/sh\n[ \"$1\" = new ] && printf '%s' '\(target.path)' > \"$TITAN_CD_FILE\"\nexit 0\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let hook = root.appendingPathComponent("hook")
        try Data(ShellHook.script(for: shell, titan: fake.path)!.utf8).write(to: hook)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/\(shell)")
        p.arguments = ["-c", "export HOME='\(root.path)'; cd '\(root.path)'; source '\(hook.path)'; titan new shop; echo \"PWD=$PWD\"; titan ps; echo \"PWD2=$PWD\""]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.contains("PWD=\(target.path)"))
        #expect(text.contains("PWD2=\(target.path)"))   // other commands don't move the shell
    }
}

@Suite struct ImplicitCreationTests {
    @Test func runRefusesToCreateAVMInAFolderThatIsntAProject() throws {
        let t = try TempProject(["notes.txt": "hi"])
        let rt = FakeRuntime()
        let engine = makeEngine(t.project, rt)
        #expect(throws: TitanError.self) { try engine.run(["ls"], cwd: t.project.root.path) }
        #expect(rt.runs.isEmpty)
        // An explicit `titan up` still works, and afterwards run is fine.
        try engine.up()
        #expect(throws: ReplacedProcess.self) { try engine.run(["ls"], cwd: t.project.root.path) }
    }

    @Test func manifestsAndConfigCountAsProjects() throws {
        // Keep each TempProject alive while checking: it deletes its folder when released.
        func recognized(_ files: [String: String]) throws -> Bool { let t = try TempProject(files); return t.project.isRecognized }
        #expect(try recognized(["go.mod": "go 1.23\n"]))
        #expect(try recognized([".devcontainer.json": "{}"]))
        #expect(try recognized(["titan.lock": "{}"]))
        #expect(try !recognized(["a.txt": ""]))
    }
}
