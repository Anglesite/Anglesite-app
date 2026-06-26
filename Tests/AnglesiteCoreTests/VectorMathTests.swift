import Testing
@testable import AnglesiteCore

@Suite("VectorMath")
struct VectorMathTests {
    @Test("cosine of identical unit vectors is 1")
    func identical() {
        #expect(abs(VectorMath.cosine([1, 0, 0], [1, 0, 0]) - 1.0) < 0.0001)
    }

    @Test("cosine of orthogonal vectors is 0")
    func orthogonal() {
        #expect(abs(VectorMath.cosine([1, 0], [0, 1])) < 0.0001)
    }

    @Test("cosine returns 0 for mismatched lengths or zero vectors")
    func degenerate() {
        #expect(VectorMath.cosine([1, 0], [1, 0, 0]) == 0)
        #expect(VectorMath.cosine([0, 0], [1, 0]) == 0)
    }

    @Test("stableHash is deterministic and content-sensitive")
    func stableHash() {
        #expect(VectorMath.stableHash("pricing") == VectorMath.stableHash("pricing"))
        #expect(VectorMath.stableHash("pricing") != VectorMath.stableHash("about"))
    }
}
