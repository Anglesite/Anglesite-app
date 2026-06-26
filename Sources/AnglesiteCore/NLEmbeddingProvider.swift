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
        let floats = raw.map { Float($0) }
        let magnitude = (floats.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard magnitude > 0 else { throw EmbeddingError.modelUnavailable }
        return floats.map { $0 / magnitude }
    }
}
