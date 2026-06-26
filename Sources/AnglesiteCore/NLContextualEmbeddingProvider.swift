import Foundation
import NaturalLanguage
import os

/// Production ``EmbeddingProvider`` backed by Apple's on-device `NLContextualEmbedding` — a
/// transformer embedding model that is higher quality and broader-language than
/// `NLEmbedding.sentenceEmbedding`, which matters for i18n sites (#312). Token vectors are
/// mean-pooled into a single unit-normalized passage vector.
///
/// `init?` returns `nil` when the model's assets aren't available on the host (so callers fall
/// back to ``NLEmbeddingProvider`` and then to lexical-only). Per-call language detection lets one
/// loaded model embed mixed-language content reasonably; loading distinct per-script models is a
/// further enhancement.
public struct NLContextualEmbeddingProvider: EmbeddingProvider {
    private static let log = Logger(subsystem: "io.dwk.anglesite", category: "NLContextualEmbeddingProvider")

    private let model: NLContextualEmbedding
    private let defaultLanguage: NLLanguage
    public let dimension: Int

    public init?(language: NLLanguage = .english) {
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        // Assets ship on demand; without them the model can't embed, so bail to the fallback chain
        // rather than load lazily mid-query (which would block the actor on a download).
        guard model.hasAvailableAssets else { return nil }
        do {
            try model.load()
        } catch {
            return nil
        }
        self.model = model
        self.defaultLanguage = language
        self.dimension = model.dimension
    }

    public func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.emptyText }

        let language = Self.detectLanguage(trimmed) ?? defaultLanguage
        let result = try model.embeddingResult(for: trimmed, language: language)

        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            guard vector.count == dimension else {
                // `model.dimension` and the result's token vectors disagree — a framework/programmer
                // error, not recoverable data. Trap in debug; in release, skip with a diagnostic
                // rather than silently distorting the mean-pool.
                assertionFailure("NLContextualEmbedding dimension mismatch: expected \(dimension), got \(vector.count)")
                Self.log.error("token vector dimension mismatch: expected \(dimension), got \(vector.count)")
                return true
            }
            for i in 0..<dimension { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { throw EmbeddingError.modelUnavailable }

        let mean = sum.map { Float($0 / Double(count)) }
        let magnitude = (mean.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard magnitude > 0 else { throw EmbeddingError.modelUnavailable }
        return mean.map { $0 / magnitude }
    }

    private static func detectLanguage(_ text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }
}
