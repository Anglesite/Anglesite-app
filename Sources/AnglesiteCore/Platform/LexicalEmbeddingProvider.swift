import Foundation

/// Portable, deterministic ``EmbeddingProvider`` fallback for platforms without an on-device
/// embedding model (``NLEmbeddingProvider``/``NLContextualEmbeddingProvider``, both Darwin-only
/// via NaturalLanguage — see ``PlatformCapabilities/hasEmbeddings``). Hashes lowercased word
/// tokens into a fixed-dimension bag-of-words vector via ``VectorMath/stableHash(_:)``, so texts
/// sharing vocabulary land closer together under cosine similarity — a real (if crude)
/// lexical-overlap signal for ``SemanticRanker``, unlike ``FakeEmbeddingProvider``'s
/// character-level projection (test-only, tuned for stability rather than usefulness).
public struct LexicalEmbeddingProvider: EmbeddingProvider {
    public let dimension: Int

    public init(dimension: Int = 256) {
        self.dimension = max(1, dimension)
    }

    public func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.emptyText }
        var vector = [Float](repeating: 0, count: dimension)
        for word in Self.tokens(of: trimmed) {
            vector[Self.bucket(for: word, dimension: dimension)] += 1
        }
        let magnitude = (vector.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard magnitude > 0 else { throw EmbeddingError.modelUnavailable }
        return vector.map { $0 / magnitude }
    }

    /// Lowercased alphanumeric word tokens. Unlike the short-word filter in
    /// `SiteGraphAugmentedAssistant.queryTerms` (a query-matching heuristic), every token counts
    /// here — this is a general-purpose embedder, not a search filter.
    static func tokens(of text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func bucket(for word: String, dimension: Int) -> Int {
        let hash = UInt64(VectorMath.stableHash(word), radix: 16) ?? 0
        return Int(hash % UInt64(dimension))
    }
}
