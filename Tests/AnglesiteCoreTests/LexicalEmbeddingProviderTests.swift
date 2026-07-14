import Foundation
import Testing
@testable import AnglesiteCore

@Suite("LexicalEmbeddingProvider")
struct LexicalEmbeddingProviderTests {
    @Test("identical text embeds to an identical, unit-normalized vector")
    func deterministicNormalized() async throws {
        let provider = LexicalEmbeddingProvider(dimension: 64)
        let a = try await provider.embed("pricing plans for teams")
        let b = try await provider.embed("pricing plans for teams")
        #expect(a == b)
        #expect(a.count == 64)
        let magnitude = (a.reduce(0) { $0 + $1 * $1 }).squareRoot()
        #expect(abs(magnitude - 1.0) < 0.0001)
    }

    @Test("vocabulary overlap ranks closer than disjoint text under cosine")
    func lexicalOverlapSignal() async throws {
        let provider = LexicalEmbeddingProvider()
        let query = try await provider.embed("pricing plans for small teams")
        let overlapping = try await provider.embed("compare pricing plans")
        let disjoint = try await provider.embed("uploading vacation photographs")
        #expect(VectorMath.cosine(query, overlapping) > VectorMath.cosine(query, disjoint))
    }

    @Test("tokenization is case-insensitive and ignores punctuation")
    func caseAndPunctuation() async throws {
        let provider = LexicalEmbeddingProvider()
        let a = try await provider.embed("Pricing, Plans!")
        let b = try await provider.embed("pricing plans")
        #expect(a == b)
    }

    @Test("blank text throws emptyText")
    func blankThrows() async {
        let provider = LexicalEmbeddingProvider()
        await #expect(throws: EmbeddingError.emptyText) {
            _ = try await provider.embed("  \n\t ")
        }
    }

    @Test("text with no alphanumeric tokens throws modelUnavailable, not a zero vector")
    func noTokensThrows() async {
        let provider = LexicalEmbeddingProvider()
        await #expect(throws: EmbeddingError.modelUnavailable) {
            _ = try await provider.embed("!!! --- ???")
        }
    }

    @Test("dimension is clamped to at least 1 and buckets stay in range",
          arguments: [-4, 0, 1, 2, 256])
    func bucketRange(dimension: Int) throws {
        let provider = LexicalEmbeddingProvider(dimension: dimension)
        #expect(provider.dimension >= 1)
        for word in ["a", "pricing", "🎉emoji🎉", String(repeating: "z", count: 300)] {
            let bucket = LexicalEmbeddingProvider.bucket(for: word, dimension: provider.dimension)
            #expect((0..<provider.dimension).contains(bucket))
        }
    }

    @Test("tokens(of:) splits on non-alphanumerics and lowercases")
    func tokens() {
        #expect(LexicalEmbeddingProvider.tokens(of: "Hello, wide-open World_2") ==
            ["hello", "wide", "open", "world", "2"])
        #expect(LexicalEmbeddingProvider.tokens(of: "...").isEmpty)
    }

    @Test("bucket parses every stableHash value — repeated words accumulate weight")
    func repeatedWordsAccumulate() async throws {
        let provider = LexicalEmbeddingProvider(dimension: 512)
        let once = try await provider.embed("pricing details")
        let repeated = try await provider.embed("pricing pricing pricing details")
        // More mass on "pricing"'s bucket after normalization → vectors differ.
        #expect(once != repeated)
        // But they still share all vocabulary, so similarity stays high.
        #expect(VectorMath.cosine(once, repeated) > 0.7)
    }
}
