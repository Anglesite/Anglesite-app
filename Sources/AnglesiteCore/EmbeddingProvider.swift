import Foundation

/// An error surfaced by an ``EmbeddingProvider``.
public enum EmbeddingError: Error, Equatable {
    /// The text to embed was empty or whitespace-only.
    case emptyText
    /// No on-device embedding model/asset is available at runtime.
    case modelUnavailable
}

/// Produces a fixed-length, unit-normalized embedding for a string. The single seam the
/// semantic ranker depends on, so the model choice (Apple NaturalLanguage in production, a
/// deterministic fake in tests) is swappable without touching ranking logic.
public protocol EmbeddingProvider: Sendable {
    /// The length of every vector this provider returns.
    var dimension: Int { get }
    /// Returns a unit-normalized embedding, or throws if the text is empty / no model is available.
    func embed(_ text: String) async throws -> [Float]
}

/// Deterministic embedding for tests: a stable bag-of-characters projection, unit-normalized.
/// Not semantically meaningful — only stable and content-sensitive, which is all the ranker,
/// cache, and incremental-update tests need.
public struct FakeEmbeddingProvider: EmbeddingProvider {
    public let dimension: Int

    public init(dimension: Int = 8) {
        self.dimension = max(1, dimension)
    }

    public func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.emptyText }
        var vector = [Float](repeating: 0, count: dimension)
        for scalar in trimmed.unicodeScalars {
            vector[Int(scalar.value) % dimension] += 1
        }
        let magnitude = (vector.reduce(0) { $0 + $1 * $1 }).squareRoot()
        // Unreachable for non-empty trimmed input (every scalar increments a bucket), but label it
        // accurately if it ever triggers: a zero vector is a failed embedding, not empty input.
        guard magnitude > 0 else { throw EmbeddingError.modelUnavailable }
        return vector.map { $0 / magnitude }
    }
}
