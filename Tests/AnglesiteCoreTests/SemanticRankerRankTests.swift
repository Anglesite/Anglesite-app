import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SemanticRanker rank")
struct SemanticRankerRankTests {
    private func doc(_ id: String, body: String) -> SiteKnowledgeIndex.Document {
        SiteKnowledgeIndex.Document(
            id: id, siteID: "s", path: "\(id).md", kind: .page, title: id,
            frontmatter: [:], headings: [], internalLinks: [], excerptText: body,
            lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("related ranks the most similar document first and excludes self")
    func related() async {
        let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        await ranker.sync(siteID: "s", documents: [
            doc("a", body: "pricing plans pricing plans"),
            doc("b", body: "pricing plans for teams"),   // close to a
            doc("c", body: "zzzz qqqq wholly different"), // far from a
        ])
        let ranked = await ranker.related(siteID: "s", toDocID: "a", limit: 5)
        #expect(!ranked.contains { $0.docID == "a" })
        #expect(ranked.first?.docID == "b")
    }

    @Test("search ranks by similarity to the query text")
    func search() async {
        let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        await ranker.sync(siteID: "s", documents: [
            doc("a", body: "pricing plans for teams"),
            doc("b", body: "completely unrelated content here"),
        ])
        let ranked = await ranker.search(siteID: "s", queryText: "pricing plans for teams", limit: 5)
        #expect(ranked.first?.docID == "a")
    }

    @Test("a flat (all-equal) signal contributes 0, letting the other signal decide")
    func blendFlatSignal() {
        // All lexical scores equal → no discriminating signal → normalizes to 0, so semantic
        // decides and the lexical side does not inflate every doc (the #1 review fix).
        let result = SemanticRanker.blend(
            lexical: ["a": 5, "b": 5],
            semantic: ["a": 0, "b": 1],
            semanticWeight: 0.6)
        #expect(abs((result["a"] ?? -1) - 0.0) < 0.0001)   // 0.6*0 + 0.4*0
        #expect(abs((result["b"] ?? -1) - 0.6) < 0.0001)   // 0.6*1 + 0.4*0
    }

    @Test("blend normalizes and weights both signals")
    func blend() {
        let result = SemanticRanker.blend(
            lexical: ["a": 10, "b": 0],
            semantic: ["a": 0, "b": 1],
            semanticWeight: 0.5)
        // a: 0.5*0 + 0.5*1 = 0.5 ; b: 0.5*1 + 0.5*0 = 0.5
        #expect(abs((result["a"] ?? -1) - 0.5) < 0.0001)
        #expect(abs((result["b"] ?? -1) - 0.5) < 0.0001)
    }
}
