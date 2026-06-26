import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SemanticRanker sync")
struct SemanticRankerSyncTests {
    /// Counts how many times embed() ran, so cache-hit behavior is observable.
    ///
    /// `@unchecked Sendable` with an unguarded counter is safe here *only* because
    /// `SemanticRanker.sync`/`upsert` embed documents strictly sequentially (no `TaskGroup`), so
    /// `embed` is never called concurrently. If that loop is ever parallelized, replace this with an
    /// actor or a locked counter.
    final class CountingProvider: EmbeddingProvider, @unchecked Sendable {
        let dimension = 8
        private(set) var calls = 0
        func embed(_ text: String) async throws -> [Float] {
            calls += 1
            return try await FakeEmbeddingProvider(dimension: 8).embed(text)
        }
    }

    private func doc(_ id: String, title: String, body: String) -> SiteKnowledgeIndex.Document {
        SiteKnowledgeIndex.Document(
            id: id, siteID: "s", path: "\(id).md", kind: .page, title: title,
            frontmatter: [:], headings: [], internalLinks: [], excerptText: body,
            lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("embeddedText joins title, headings, and a 2000-char-truncated excerpt")
    func embeddedTextFormat() {
        let longBody = String(repeating: "x", count: 5000)
        let document = SiteKnowledgeIndex.Document(
            id: "d", siteID: "s", path: "d.md", kind: .page, title: "My Title",
            frontmatter: [:], headings: ["Intro", "Details"], internalLinks: [], excerptText: longBody,
            lastModified: Date(timeIntervalSince1970: 0))
        let text = SemanticRanker.embeddedText(for: document)
        #expect(text.hasPrefix("My Title\nIntro Details\n"))
        #expect(text.contains(String(repeating: "x", count: 2000)))
        #expect(!text.contains(String(repeating: "x", count: 2001)))
    }

    @Test("sync embeds each document once")
    func embedsEach() async {
        let provider = CountingProvider()
        let ranker = SemanticRanker(provider: provider, cache: nil)
        await ranker.sync(siteID: "s", documents: [
            doc("a", title: "Pricing", body: "plans"),
            doc("b", title: "About", body: "team"),
        ])
        #expect(provider.calls == 2)
        #expect(await ranker.vectorCount(siteID: "s") == 2)
    }

    @Test("re-sync with unchanged content does not re-embed")
    func cachesUnchanged() async {
        let provider = CountingProvider()
        let ranker = SemanticRanker(provider: provider, cache: nil)
        let docs = [doc("a", title: "Pricing", body: "plans")]
        await ranker.sync(siteID: "s", documents: docs)
        await ranker.sync(siteID: "s", documents: docs)
        #expect(provider.calls == 1)
    }

    @Test("sync drops vectors for removed documents")
    func dropsRemoved() async {
        let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        await ranker.sync(siteID: "s", documents: [doc("a", title: "A", body: "x"), doc("b", title: "B", body: "y")])
        await ranker.sync(siteID: "s", documents: [doc("a", title: "A", body: "x")])
        #expect(await ranker.vectorCount(siteID: "s") == 1)
    }

    @Test("cache lets a fresh ranker skip embedding")
    func warmCacheSkipsEmbed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sem-\(UUID().uuidString)/caches/semantic-index.json")
        let docs = [doc("a", title: "Pricing", body: "plans")]
        let first = SemanticRanker(provider: CountingProvider(), cache: SemanticIndexCache(fileURL: url))
        await first.sync(siteID: "s", documents: docs)

        let warmProvider = CountingProvider()
        let second = SemanticRanker(provider: warmProvider, cache: SemanticIndexCache(fileURL: url))
        await second.sync(siteID: "s", documents: docs)
        #expect(warmProvider.calls == 0)
    }
}
