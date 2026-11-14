import Foundation
import Testing
@testable import TitanCore

@Suite struct JSONCTests {
    @Test func stripsCommentsAndTrailingCommas() throws {
        let text = """
        {
          // line comment
          "image": "node:22", /* block */
          "url": "http://example.com/a//b", // slashes inside strings survive
          "list": [1, 2,],
        }
        """
        let obj = try JSONSerialization.jsonObject(with: Data(JSONC.strip(text).utf8)) as! [String: Any]
        #expect(obj["image"] as? String == "node:22")
        #expect(obj["url"] as? String == "http://example.com/a//b")
        #expect((obj["list"] as? [Int]) == [1, 2])
    }

    @Test func handlesCRLFLineComments() throws {
        let text = "{\r\n// c\r\n\"a\": 1\r\n}"
        let obj = try JSONSerialization.jsonObject(with: Data(JSONC.strip(text).utf8)) as! [String: Any]
        #expect(obj["a"] as? Int == 1)
    }
}

@Suite struct DevContainerConfigTests {
    @Test func parsesSupportedSubset() throws {
        let c = try DevContainerConfig.parse("""
        {
          "image": "python:3.12",
          "forwardPorts": [8000, "db:5432", "weird"],
          "remoteEnv": {"A": "1", "B": null},
          "postCreateCommand": {"deps": "pip install -r r.txt", "a": ["echo", "hi"]},
          "customizations": {"vscode": {"extensions": ["x"]}, "titan": {"shims": ["python"], "cpus": 4}}
        }
        """)
        #expect(c.image == "python:3.12")
        #expect(c.forwardPorts == [8000, 5432])
        #expect(c.remoteEnv == ["A": "1"])
        #expect(c.titan?.shims == ["python"])
        #expect(c.titan?.cpus == 4)
        #expect(c.postCreateCommand?.steps == [["echo", "hi"], ["/bin/sh", "-c", "pip install -r r.txt"]])
        #expect(!c.usesCompose)
    }

    @Test func flagsCompose() throws {
        let c = try DevContainerConfig.parse(#"{"dockerComposeFile": "x.yml", "service": "app"}"#)
        #expect(c.usesCompose)
    }
}

@Suite struct ResolverTests {
    @Test func devcontainerWinsOverDetection() throws {
        let t = try TempProject([
            "package.json": "{}",
            ".devcontainer/devcontainer.json": #"{"image": "custom:1", "forwardPorts": [5173]}"#,
        ])
        let env = try EnvironmentResolver.resolve(t.project)
        #expect(env.image == .pull("custom:1"))
        #expect(env.ports == [5173])
        #expect(env.shims == ["node", "npm", "npx"])  // falls back to detected shims
        #expect(env.workspaceFolder == "/workspaces/\(t.project.name)")
    }

    @Test func dockerfileBuildIsResolvedRelativeToConfig() throws {
        let t = try TempProject([
            ".devcontainer/devcontainer.json": #"{"build": {"dockerfile": "Dockerfile", "context": ".."}}"#,
            ".devcontainer/Dockerfile": "FROM alpine\n",
        ])
        let env = try EnvironmentResolver.resolve(t.project)
        guard case .build(let df, let ctx, _, let hash) = env.image else { Issue.record("expected build"); return }
        #expect(df.hasSuffix(".devcontainer/Dockerfile"))
        #expect(Project.canonical(URL(fileURLWithPath: ctx)) == t.project.root)
        #expect(!hash.isEmpty)
    }

    @Test func dockerfileEditChangesHash() throws {
        let t = try TempProject([
            ".devcontainer/devcontainer.json": #"{"build": {"dockerfile": "Dockerfile"}}"#,
            ".devcontainer/Dockerfile": "FROM alpine\n",
        ])
        let before = try EnvironmentResolver.resolve(t.project).configHash
        try t.write(".devcontainer/Dockerfile", "FROM alpine\nRUN apk add git\n")
        #expect(try EnvironmentResolver.resolve(t.project).configHash != before)
    }

    @Test func invalidConfigReportsPath() throws {
        let t = try TempProject([".devcontainer.json": "{ nope"])
        #expect(throws: TitanError.self) { try EnvironmentResolver.resolve(t.project) }
    }

    @Test func shimChangesDoNotForceRebuild() throws {
        let t = try TempProject([".devcontainer.json": #"{"image": "x", "customizations": {"titan": {"shims": ["a"]}}}"#])
        let a = try EnvironmentResolver.resolve(t.project).configHash
        try t.write(".devcontainer.json", #"{"image": "x", "customizations": {"titan": {"shims": ["a", "b"]}}}"#)
        #expect(try EnvironmentResolver.resolve(t.project).configHash == a)
    }
}
