import Foundation
import Testing
@testable import AnglesiteCore

// Gated for the same reason as the type under test — NaturalLanguage is a Darwin-only
// framework (see NLEmbeddingProvider.swift's canImport(NaturalLanguage) guard).
#if canImport(NaturalLanguage)
import NaturalLanguage

@Suite("NLEmbeddingProvider")
struct NLEmbeddingProviderTests {
    @Test("when a model is available, embeddings are unit-normalized and similar text ranks closer")
    func embeds() async throws {
        guard let provider = NLEmbeddingProvider() else {
            // No sentence-embedding asset on this host (e.g. minimal CI image) — nothing to verify.
            return
        }
        let pricing = try await provider.embed("our pricing and subscription plans")
        let plans = try await provider.embed("subscription pricing tiers")
        let weather = try await provider.embed("today's weather forecast")
        let magnitude = (pricing.reduce(0) { $0 + $1 * $1 }).squareRoot()
        #expect(abs(magnitude - 1.0) < 0.001)
        #expect(VectorMath.cosine(pricing, plans) > VectorMath.cosine(pricing, weather))
    }
}
#endif
