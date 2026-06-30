import Foundation
import Testing
@testable import AnglesiteCore

#if compiler(>=6.4)
@Suite("SuggestLinksTool")
struct SuggestLinksToolTests {
    private func doc(
        _ path: String,
        title: String? = nil,
        kind: SiteKnowledgeIndex.Document.Kind = .page,
        links: [String] = [],
        body: String = ""
    ) -> SiteKnowledgeIndex.Document {
        SiteKnowledgeIndex.Document(
            id: "s:knowledge:\(path)", siteID: "s", path: path, kind: kind,
            title: title ?? path, frontmatter: [:], headings: [],
            internalLinks: links, excerptText: body,
            lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("suggests semantically related pages not already linked")
    func suggestsRelatedUnlinked() async {
        let docs = [
            doc("src/pages/pricing.astro", title: "Pricing", links: ["/about"],
                body: "pricing plans for teams and individuals"),
            doc("src/pages/about.astro", title: "About Us",
                body: "about our company and team"),
            doc("src/pages/teams.astro", title: "Teams",
                body: "pricing plans for teams enterprise"),
            doc("src/pages/unrelated.astro", title: "Blog",
                body: "completely different blog content xyz"),
        ]
        let suggestions = LinkGraph.suggestLinks(
            forDocumentAt: "src/pages/pricing.astro",
            in: docs,
            rankedRelated: [
                SemanticRanker.Ranked(docID: "s:knowledge:src/pages/teams.astro", score: 0.95),
                SemanticRanker.Ranked(docID: "s:knowledge:src/pages/about.astro", score: 0.80),
                SemanticRanker.Ranked(docID: "s:knowledge:src/pages/unrelated.astro", score: 0.30),
            ],
            limit: 5
        )
        // "about" is already linked from pricing → filtered out
        #expect(!suggestions.contains { $0.path == "src/pages/about.astro" })
        // "teams" is semantically related and not linked → suggested
        #expect(suggestions.contains { $0.path == "src/pages/teams.astro" })
    }

    @Test("returns empty when all related pages are already linked")
    func allAlreadyLinked() async {
        let docs = [
            doc("src/pages/index.astro", links: ["/about", "/pricing"],
                body: "home page with links"),
            doc("src/pages/about.astro", title: "About", body: "about page"),
            doc("src/pages/pricing.astro", title: "Pricing", body: "pricing page"),
        ]
        let suggestions = LinkGraph.suggestLinks(
            forDocumentAt: "src/pages/index.astro",
            in: docs,
            rankedRelated: [
                SemanticRanker.Ranked(docID: "s:knowledge:src/pages/about.astro", score: 0.9),
                SemanticRanker.Ranked(docID: "s:knowledge:src/pages/pricing.astro", score: 0.8),
            ],
            limit: 5
        )
        #expect(suggestions.isEmpty)
    }

    @Test("returns empty for unknown path")
    func unknownPath() async {
        let suggestions = LinkGraph.suggestLinks(
            forDocumentAt: "src/pages/nonexistent.astro",
            in: [],
            rankedRelated: [],
            limit: 5
        )
        #expect(suggestions.isEmpty)
    }

    @Test("call returns message for empty path")
    func callEmptyPath() async throws {
        let index = SiteKnowledgeIndex()
        let tool = SuggestLinksTool(index: index, siteID: "s")
        let out = try await tool.call(arguments: .init(path: "  "))
        #expect(out.contains("Provide a file path"))
    }

    @Test("call returns message for unknown document")
    func callUnknownDoc() async throws {
        let index = SiteKnowledgeIndex()
        let tool = SuggestLinksTool(index: index, siteID: "s")
        let out = try await tool.call(arguments: .init(path: "src/pages/nope.astro"))
        #expect(out.contains("No indexed document"))
    }

    @Test("call returns unavailable message when no ranker is provided")
    func callNoRanker() async throws {
        let index = SiteKnowledgeIndex()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("suggest-tool-\(UUID().uuidString)", isDirectory: true)
        let pagesDir = root.appendingPathComponent("src/pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        try Data("---\ntitle: About\n---\nAbout us.".utf8).write(to: pagesDir.appendingPathComponent("about.astro"))
        await index.rebuild(siteID: "s", projectRoot: root)

        let tool = SuggestLinksTool(index: index, siteID: "s", ranker: nil)
        let out = try await tool.call(arguments: .init(path: "src/pages/about.astro"))
        #expect(out.contains("Semantic ranking is unavailable"))
    }
}
#endif
