import Foundation
import Testing
@testable import AnglesiteCore

@Suite("LexicalEmbeddingProvider")
struct LexicalEmbeddingProviderTests {
    @Test("deterministic and unit-normalized")
    func deterministicNormalized() async throws {
        let provider = LexicalEmbeddingProvider(dimension: 256)
        let a = try await provider.embed("pricing plans for teams")
        let b = try await provider.embed("pricing plans for teams")
        #expect(a == b)
        #expect(a.count == 256)
        let magnitude = (a.reduce(0) { $0 + $1 * $1 }).squareRoot()
        #expect(abs(magnitude - 1.0) < 0.0001)
    }

    @Test("blank text throws emptyText")
    func blankThrows() async {
        let provider = LexicalEmbeddingProvider(dimension: 256)
        await #expect(throws: EmbeddingError.emptyText) {
            _ = try await provider.embed("   ")
        }
    }

    @Test("shared vocabulary ranks closer than unrelated text")
    func sharedVocabularyRanksCloser() async throws {
        let provider = LexicalEmbeddingProvider(dimension: 256)
        let pricing = try await provider.embed("our pricing and subscription plans")
        let plans = try await provider.embed("subscription pricing tiers")
        let weather = try await provider.embed("today's weather forecast")
        #expect(VectorMath.cosine(pricing, plans) > VectorMath.cosine(pricing, weather))
    }
}
