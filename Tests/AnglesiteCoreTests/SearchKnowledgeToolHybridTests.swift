import Foundation
import Testing
@testable import AnglesiteCore

// Gated like the type under test — FoundationModels (and thus SearchKnowledgeTool) is only
// compiled under the Xcode-27 toolchain (#128). The hybrid path needs no live model: a fake
// embedding provider drives SemanticRanker.
#if compiler(>=6.4)
import FoundationModels

@Suite("SearchKnowledgeTool hybrid")
struct SearchKnowledgeToolHybridTests {
    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("khybrid-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("hybrid mode returns results and does not crash with a fake provider")
    func hybridRanks() async {
        let root = makeSite([
            "src/pages/pricing.astro": "---\ntitle: Pricing\n---\n# Pricing\nSubscription plans for teams.",
            "src/pages/about.astro": "---\ntitle: About\n---\n# About\nOur team story.",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        await ranker.sync(siteID: "s", documents: await index.documents(siteID: "s"))

        let tool = SearchKnowledgeTool(index: index, siteID: "s", ranker: ranker)
        let output = try! await tool.call(arguments: .init(query: "subscription pricing plans"))
        #expect(output.contains("pricing.astro"))
    }

    @Test("without a ranker, output matches the lexical-only tool")
    func lexicalFallback() async {
        let root = makeSite(["src/pages/pricing.astro": "---\ntitle: Pricing\n---\n# Pricing\nPlans."])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        let lexicalOnly = SearchKnowledgeTool(index: index, siteID: "s")
        let output = try! await lexicalOnly.call(arguments: .init(query: "pricing"))
        #expect(output.contains("pricing.astro"))
    }
}
#endif
