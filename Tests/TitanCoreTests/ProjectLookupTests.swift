import Foundation
import Testing
@testable import TitanCore

@Suite struct ProjectLookupTests {
    let shop = Project(root: URL(fileURLWithPath: "/Users/me/code/shop"))
    let blog = Project(root: URL(fileURLWithPath: "/Users/me/code/blog"))
    let shopClone = Project(root: URL(fileURLWithPath: "/Users/me/work/shop"))

    @Test func byProjectNameCaseInsensitive() throws {
        #expect(try ProjectLookup.find("blog", in: [shop, blog]) == .project(blog))
        #expect(try ProjectLookup.find("Shop", in: [shop, blog]) == .project(shop))
    }

    @Test func byVMNameIncludingServices() throws {
        #expect(try ProjectLookup.find(shop.containerName, in: [shop, blog]) == .project(shop))
        #expect(try ProjectLookup.find(shop.containerName + "-postgres", in: [shop, blog]) == .service(shop, "postgres"))
        #expect(try ProjectLookup.find("shop/redis", in: [shop, blog]) == .service(shop, "redis"))
    }

    @Test func duplicateNamesNeedTheVMNameOrFolder() throws {
        #expect(throws: TitanError.self) { try ProjectLookup.find("shop", in: [shop, shopClone]) }
        #expect(try ProjectLookup.find(shopClone.containerName, in: [shop, shopClone]) == .project(shopClone))
    }

    @Test func unknownNamesListWhatsKnown() {
        do {
            _ = try ProjectLookup.find("nope", in: [shop, blog])
            Issue.record("expected an error")
        } catch let e as TitanError {
            #expect(e.description.contains("Known projects: blog, shop"))
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test func byPath() throws {
        let t = try TempProject(["package.json": "{}", "src/a.js": ""])
        #expect(try ProjectLookup.find(t.url.path, in: []) == .project(t.project))
        #expect(try ProjectLookup.find("./src", in: [], cwd: t.url.path) == .project(t.project))   // walks up to the root
        #expect(throws: TitanError.self) { try ProjectLookup.find("/no/such/folder", in: []) }
    }
}
