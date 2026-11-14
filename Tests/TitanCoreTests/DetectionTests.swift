import Foundation
import Testing
@testable import TitanCore

@Suite struct DetectionTests {
    @Test func nodeWithNvmrcAndPnpm() throws {
        let t = try TempProject(["package.json": "{}", ".nvmrc": "v20.11.1\n", "pnpm-lock.yaml": ""])
        let d = StackDetector.detect(at: t.url)
        #expect(d.kind == "node")
        #expect(d.image == "node:20-bookworm")
        #expect(d.setup == ["corepack enable && pnpm install --frozen-lockfile"])
        #expect(d.shims.contains("pnpm"))
    }

    @Test func nodeEnginesField() throws {
        let t = try TempProject(["package.json": #"{"engines": {"node": ">=18.0.0"}}"#, "package-lock.json": "{}"])
        let d = StackDetector.detect(at: t.url)
        #expect(d.image == "node:18-bookworm")
        #expect(d.setup == ["npm ci"])
    }

    @Test func pythonVersionFile() throws {
        let t = try TempProject(["requirements.txt": "flask\n", ".python-version": "3.11.7\n"])
        let d = StackDetector.detect(at: t.url)
        #expect(d.image == "python:3.11-bookworm")
        #expect(d.setup == ["pip install -r requirements.txt"])
    }

    @Test func pythonRequiresPython() throws {
        let t = try TempProject(["pyproject.toml": "[project]\nrequires-python = \">=3.10\"\n"])
        #expect(StackDetector.detect(at: t.url).image == "python:3.10-bookworm")
    }

    @Test func goModVersion() throws {
        let t = try TempProject(["go.mod": "module x\n\ngo 1.22.3\n"])
        #expect(StackDetector.detect(at: t.url).image == "golang:1.22-bookworm")
    }

    @Test func fallsBackToGeneric() throws {
        let t = try TempProject(["README.md": "hi"])
        #expect(StackDetector.detect(at: t.url).kind == "generic")
    }

    @Test func generatedDevcontainerRoundTrips() throws {
        let t = try TempProject(["Cargo.toml": "[package]\n"])
        let text = EnvironmentResolver.generateDevcontainer(for: t.project)
        let config = try DevContainerConfig.parse(text)
        #expect(config.image == "rust:1-bookworm")
        #expect(config.titan?.shims == ["cargo", "rustc", "rustup"])
    }
}
