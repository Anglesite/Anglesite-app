import Foundation
import NaturalLanguage

/// Production ``EmbeddingProvider`` backed by Apple's on-device `NLEmbedding.sentenceEmbedding`.
/// Synchronous and asset-light, so it works without a network embedding service (project
/// strategy). Returns `nil` from init when no model is available, letting callers degrade to
/// lexical-only ranking.
public struct NLEmbeddingProvider: EmbeddingProvider {
    private let embedding: NLEmbedding
    public let dimension: Int

    public init?(language: NLLanguage = .english) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        self.embedding = embedding
        self.dimension = embedding.dimension
    }

    public func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.emptyText }
        guard let raw = embedding.vector(for: trimmed) else { throw EmbeddingError.modelUnavailable }
        // Despite the documented contract, `sentenceEmbedding.vector(for:)` does NOT return a unit
        // vector here (verified: magnitudes ≠ 1) — so normalize to honor the EmbeddingProvider
        // contract. (Ranking via `VectorMath.cosine` is scale-invariant regardless, but other
        // consumers may rely on unit length.) A degenerate zero vector means the model produced
        // nothing usable for this input.
        let floats = raw.map { Float($0) }
        let magnitude = (floats.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard magnitude > 0 else { throw EmbeddingError.modelUnavailable }
        return floats.map { $0 / magnitude }
    }
}
