import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SiteKnowledgeIndex")
struct SiteKnowledgeIndexTests {
    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-index-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("rebuild indexes pages, components, layouts, config, and skips build artifacts")
    func rebuildIndexesProjectKnowledge() async {
        let root = makeSite([
            "src/pages/pricing.astro": "---\ntitle: Pricing\n---\n# Plans\n<a href=\"/contact\">Talk to sales</a>",
            "src/components/CTA.astro": "<button>Talk to sales</button>",
            "src/layouts/BaseLayout.astro": "<slot />",
            "astro.config.mjs": "export default {}",
            "node_modules/pkg/index.js": "should not be indexed",
            "dist/index.html": "built output",
        ])
        let index = SiteKnowledgeIndex()

        await index.rebuild(siteID: "site-1", projectRoot: root)

        let docs = await index.documents(siteID: "site-1")
        #expect(docs.map(\.path) == [
            "astro.config.mjs",
            "src/components/CTA.astro",
            "src/layouts/BaseLayout.astro",
            "src/pages/pricing.astro",
        ])
        #expect(docs.first { $0.path == "src/pages/pricing.astro" }?.kind == .page)
        #expect(docs.first { $0.path == "src/pages/pricing.astro" }?.title == "Pricing")
        #expect(docs.first { $0.path == "src/pages/pricing.astro" }?.internalLinks == ["/contact"])
    }

    @Test("search ranks title and path matches above body-only matches")
    func searchRanksUsefulMatches() async {
        let root = makeSite([
            "src/pages/pricing.astro": "---\ntitle: Pricing\n---\n# Pricing\nSimple plans for teams.",
            "src/components/Footer.astro": "<footer>See pricing for details.</footer>",
            "src/pages/about.astro": "# About\nNothing relevant.",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site-1", projectRoot: root)

        let results = await index.search(siteID: "site-1", query: "pricing", options: .init(limit: 3))

        #expect(results.first?.document.path == "src/pages/pricing.astro")
        #expect(results.first?.excerpt.contains("Pricing") == true)
        #expect(results.first?.lineRange?.lowerBound != nil)
        #expect(results.map(\.document.path).contains("src/components/Footer.astro"))
        #expect(!results.map(\.document.path).contains("src/pages/about.astro"))
    }

    @Test("upsert and remove update a single indexed file")
    func upsertAndRemove() async {
        let root = makeSite([
            "src/pages/index.astro": "# Home",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site-1", projectRoot: root)

        let newFile = root.appendingPathComponent("src/components/Hero.astro")
        try! FileManager.default.createDirectory(at: newFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("<section>Summer launch CTA</section>".utf8).write(to: newFile)
        await index.upsertFile(siteID: "site-1", projectRoot: root, relativePath: "src/components/Hero.astro")

        var results = await index.search(siteID: "site-1", query: "summer launch")
        #expect(results.first?.document.path == "src/components/Hero.astro")

        await index.removeFile(siteID: "site-1", relativePath: "src/components/Hero.astro")
        results = await index.search(siteID: "site-1", query: "summer launch")
        #expect(results.isEmpty)
    }

    @Test("rebuild stores bounded excerpts instead of full source")
    func rebuildStoresBoundedExcerpts() async {
        let longBody = String(repeating: "a", count: 9_000)
        let root = makeSite([
            "src/pages/long.astro": "# Long\n\(longBody)",
        ])
        let index = SiteKnowledgeIndex()

        await index.rebuild(siteID: "site-1", projectRoot: root)

        let document = await index.documents(siteID: "site-1").first
        #expect(document?.excerptText.count == 8_192)
    }

    @Test("search scores frontmatter separately from body text")
    func searchDoesNotDoubleCountFrontmatter() async {
        let root = makeSite([
            "src/content/example.md": "---\nsummary: launchword\n---\nNo body match here.",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site-1", projectRoot: root)

        let result = await index.search(siteID: "site-1", query: "launchword").first

        #expect(result?.score == 3)
        #expect(result?.excerpt.contains("summary: launchword") == false)
    }

    @Test("unload removes only the requested site")
    func unloadRemovesOnlyRequestedSite() async {
        let rootA = makeSite(["src/pages/a.astro": "# Alpha"])
        let rootB = makeSite(["src/pages/b.astro": "# Beta"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "a", projectRoot: rootA)
        await index.rebuild(siteID: "b", projectRoot: rootB)

        await index.unload(siteID: "a")

        #expect(await index.search(siteID: "a", query: "alpha").isEmpty)
        #expect(await index.search(siteID: "b", query: "beta").count == 1)
    }
}
