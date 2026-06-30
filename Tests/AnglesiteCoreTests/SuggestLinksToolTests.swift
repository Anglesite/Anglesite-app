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

    private func setup(_ docs: [SiteKnowledgeIndex.Document]) async -> (SiteKnowledgeIndex, SemanticRanker) {
        let index = SiteKnowledgeIndex()
        // Manually load documents by rebuilding from a temp directory isn't practical;
        // use upsertFile indirectly by populating via rebuild. Instead, test through the
        // tool's output format since we can't inject documents directly.
        // For unit tests, we test LinkGraph + SemanticRanker separately and do an
        // integration-style test here with a real temp directory.
        let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        await ranker.sync(siteID: "s", documents: docs)
        return (index, ranker)
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
}
#endif
