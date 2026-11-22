import Foundation
import Testing
@testable import TitanCore

@Suite struct CreatePresetTests {
    @Test func presetsForEmptyFolders() throws {
        let node = try #require(StackDetector.preset("node"))
        #expect(node.image == "node:22-bookworm" && node.shims.contains("npm") && node.setup.isEmpty)
        #expect(node.ports == [3000, 5173])   // Next/Express and Vite
        #expect(StackDetector.preset("python@3.13")?.image == "python:3.13-bookworm")
        #expect(StackDetector.preset("Go")?.image == "golang:1-bookworm")
        #expect(StackDetector.preset("cobol") == nil)
        for name in StackDetector.presetNames { #expect(StackDetector.preset(name) != nil, "\(name)") }
    }

    @Test func generatedConfigUsesTheChosenStack() throws {
        let t = try TempProject([:])
        let text = EnvironmentResolver.generateDevcontainer(for: t.project, services: ["postgres"], stack: StackDetector.preset("python"))
        #expect(text.contains("\"image\" : \"python:3.12-bookworm\"") && text.contains("postgres") && text.contains("titan create python"))
        #expect(!text.contains("postCreateCommand"))
    }
}
