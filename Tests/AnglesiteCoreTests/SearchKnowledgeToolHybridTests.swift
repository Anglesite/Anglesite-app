import Foundation
import Testing
@testable import AnglesiteCore

// Gated like the type under test — FoundationModels (and thus SearchKnowledgeTool) is only
// compiled under the Xcode-27 toolchain (#128). The hybrid path needs no live model: the
// embedding providers below are deterministic test doubles.
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
import AnglesiteTestSupport

@Suite("SearchKnowledgeTool hybrid")
struct SearchKnowledgeToolHybridTests {

    /// Returns the index of a path token in the formatted tool output, or `Int.max` if absent —
    /// so `<` comparisons express "ranked earlier".
    private func position(of token: String, in output: String) -> Int {
        guard let range = output.range(of: token) else { return .max }
        return output.distance(from: output.startIndex, to: range.lowerBound)
    }

    /// Maps text to a 2-D vector by marker so semantic similarity can be dictated independently of
    /// lexical keyword overlap. The query string itself is treated as semantically "near".
    private struct ScriptedEmbeddingProvider: EmbeddingProvider, Sendable {
        let dimension = 2
        let queryText: String
        func embed(_ text: String) async throws -> [Float] {
            if text == queryText { return [0, 1] }
            if text.localizedCaseInsensitiveContains("near") { return [0, 1] }
            if text.localizedCaseInsensitiveContains("far") { return [1, 0] }
            return [0, 0]
        }
    }

    @Test("hybrid blend reorders results by semantics, independent of lexical keyword overlap")
    func hybridReordersBySemantics() async {
        // Both pages match the query term "team" in their body equally, so lexical scoring ties and
        // breaks by path: aaa before zzz. Semantically, only zzz is "near" the query, so the blend
        // must lift zzz above aaa — a flip a lexical-only run can never produce.
        let root = try! writeSiteTree(prefix: "khybrid", [
            "src/pages/aaa.astro": "---\ntitle: AAA\n---\nOur team works far from the topic.",
            "src/pages/zzz.astro": "---\ntitle: ZZZ\n---\nOur team works near the topic.",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        let documents = await index.documents(siteID: "s")

        let lexicalOnly = SearchKnowledgeTool(index: index, siteID: "s")
        let lexicalOut = try! await lexicalOnly.call(arguments: .init(query: "team"))
        #expect(position(of: "aaa.astro", in: lexicalOut) < position(of: "zzz.astro", in: lexicalOut))

        let ranker = SemanticRanker(provider: ScriptedEmbeddingProvider(queryText: "team"), cache: nil)
        await ranker.sync(siteID: "s", documents: documents)
        let hybrid = SearchKnowledgeTool(index: index, siteID: "s", ranker: ranker)
        let hybridOut = try! await hybrid.call(arguments: .init(query: "team"))
        #expect(position(of: "zzz.astro", in: hybridOut) < position(of: "aaa.astro", in: hybridOut))
    }

    @Test("hybrid mode tolerates a fake provider and still returns matching results")
    func hybridRanksWithFakeProvider() async {
        let root = try! writeSiteTree(prefix: "khybrid", [
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

    @Test("a nil ranker yields pure lexical output")
    func lexicalFallback() async {
        let root = try! writeSiteTree(prefix: "khybrid", ["src/pages/pricing.astro": "---\ntitle: Pricing\n---\n# Pricing\nPlans."])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        let lexicalOnly = SearchKnowledgeTool(index: index, siteID: "s")
        let output = try! await lexicalOnly.call(arguments: .init(query: "pricing"))
        #expect(output.contains("pricing.astro"))
    }
}
#endif
