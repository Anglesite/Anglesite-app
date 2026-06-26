import Foundation
import Testing
@testable import AnglesiteCore

@Suite("EmbeddingProvider")
struct EmbeddingProviderTests {
    @Test("fake provider is deterministic and unit-normalized")
    func deterministicNormalized() async throws {
        let provider = FakeEmbeddingProvider(dimension: 8)
        let a = try await provider.embed("pricing plans for teams")
        let b = try await provider.embed("pricing plans for teams")
        #expect(a == b)
        #expect(a.count == 8)
        let magnitude = (a.reduce(0) { $0 + $1 * $1 }).squareRoot()
        #expect(abs(magnitude - 1.0) < 0.0001)
    }

    @Test("different text yields different vectors")
    func differentText() async throws {
        let provider = FakeEmbeddingProvider(dimension: 8)
        let a = try await provider.embed("pricing")
        let b = try await provider.embed("about the team")
        #expect(a != b)
    }

    @Test("blank text throws emptyText")
    func blankThrows() async {
        let provider = FakeEmbeddingProvider(dimension: 8)
        await #expect(throws: EmbeddingError.emptyText) {
            _ = try await provider.embed("   ")
        }
    }
}
