import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Site identity h-card render smoke")
struct SiteIdentityRenderSmokeTests {

    static var templateDir: URL { templateRoot() }

    /// True when the template can actually be built: a Node binary plus an installed Astro.
    static var buildable: Bool { E2EPrerequisites.astroBuildable(templateDir: templateDir) }

    @Test("footer h-card renders per profile kind, and nothing when unconfigured",
          .enabled(if: SiteIdentityRenderSmokeTests.buildable))
    func rendersFooterHcard() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dataDir = Self.templateDir.appendingPathComponent("src/data", isDirectory: true)
        let profile = dataDir.appendingPathComponent("profile.json")
        let dist = Self.templateDir.appendingPathComponent("dist", isDirectory: true)

        func build() async throws {
            try? FileManager.default.removeItem(at: dist)
            let result = try await ProcessSupervisor.shared.run(
                executable: node,
                arguments: [E2EPrerequisites.astroCLIRelativePath, "build"],
                currentDirectoryURL: Self.templateDir)
            try #require(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")
        }
        func indexHTML() throws -> String {
            try String(contentsOf: dist.appendingPathComponent("index.html"), encoding: .utf8)
        }
        func writeProfile(_ json: String) throws {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try json.write(to: profile, atomically: true, encoding: .utf8)
        }

        try await TemplateBuildSerializer.shared.serialize {
            // Keep the template ship-empty no matter how this test exits.
            defer {
                try? FileManager.default.removeItem(at: dataDir)
                try? FileManager.default.removeItem(at: dist)
            }

            // 1. Unconfigured: no profile.json → no h-card in the footer.
            try? FileManager.default.removeItem(at: dataDir)
            try await build()
            #expect(!(try indexHTML().contains("h-card")))

            // 2. Business profile → h-card with contact + address mf2.
            try writeProfile("""
            {"type":"businessProfile","name":"Acme Co","telephone":"+1-555-0100",\
            "email":"hi@acme.test","streetAddress":"1 Main St","locality":"Springfield",\
            "region":"IL","postalCode":"62701","hours":["Mon-Fri 9-5"],"url":"https://acme.test"}
            """)
            try await build()
            let biz = try indexHTML()
            #expect(biz.contains("h-card"))
            #expect(biz.contains("rel=\"indieauth-metadata\""))
            #expect(biz.contains("p-name"))
            #expect(biz.contains("p-tel"))
            #expect(biz.contains("p-street-address"))
            #expect(biz.contains("rel=\"me\""))

            // 3. Personal profile → h-card without business-only address mf2.
            try writeProfile("""
            {"type":"personalProfile","name":"Ada Lovelace","description":"Mathematician",\
            "email":"ada@example.test","url":"https://ada.example.test"}
            """)
            try await build()
            let person = try indexHTML()
            #expect(person.contains("h-card"))
            #expect(person.contains("p-name"))
            #expect(person.contains("u-email"))
            #expect(!person.contains("p-street-address"))
        }
    }
}
