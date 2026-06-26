import Testing
import Foundation
@testable import AnglesiteCore

@Suite("SiteKnowledgeIndex")
struct SiteKnowledgeIndexTests {
    @Test("retrieves bounded excerpts from relevant Astro site files")
    func retrievesRelevantExcerpts() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            """
            ---
            title: Pricing
            ---
            <section>
              <h1>Simple pricing</h1>
              <PricingTable tiers={tiers} />
            </section>
            """,
            to: root.appendingPathComponent("src/pages/pricing.astro")
        )
        try write(
            """
            export const tiers = [
              { name: 'Starter', cta: 'Start free' },
              { name: 'Pro', cta: 'Talk to sales' }
            ];
            """,
            to: root.appendingPathComponent("src/components/PricingTable.astro")
        )
        try write("pricing should not come from built output", to: root.appendingPathComponent("dist/pricing.html"))

        let index = SiteKnowledgeIndex(
            siteDirectory: root,
            options: .init(maxResults: 4, excerptRadius: 1, maxExcerptCharacters: 400)
        )

        let matches = await index.search("Where is the pricing table defined?")

        #expect(matches.map(\.relativePath).contains("src/pages/pricing.astro"))
        #expect(matches.map(\.relativePath).contains("src/components/PricingTable.astro"))
        #expect(!matches.map(\.relativePath).contains("dist/pricing.html"))
        #expect(matches.allSatisfy { $0.excerpt.count <= 404 })
    }

    @Test("formatted context includes file citations and line numbers")
    func formattedContextIncludesCitations() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# About\n\nOur docs explain the launch checklist.", to: root.appendingPathComponent("src/content/docs/about.md"))

        let index = SiteKnowledgeIndex(siteDirectory: root)
        let context = await index.formattedContext(for: "launch checklist docs")

        #expect(context?.contains("Relevant project context") == true)
        #expect(context?.contains("[src/content/docs/about.md:") == true)
        #expect(context?.contains("launch checklist") == true)
    }

    private func makeSite() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/pages"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/components"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/content/docs"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("dist"),
            withIntermediateDirectories: true
        )
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
