import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ProjectConventions")
struct ProjectConventionsTests {
    @Test("apply(_:) sets the field's value and marks it userOverride")
    func applySetsOverride() {
        var conventions = ProjectConventions.empty
        conventions.apply(.altTextAverageLength(42))
        #expect(conventions.images.altTextAverageLength.value == 42)
        #expect(conventions.images.altTextAverageLength.isOverridden == true)
    }

    @Test("clearOverride(_:) reverts the field's source to inferred, keeping the value")
    func clearOverrideRevertsSource() {
        var conventions = ProjectConventions.empty
        conventions.apply(.altTextAverageLength(42))
        conventions.clearOverride(.altTextAverageLength)
        #expect(conventions.images.altTextAverageLength.value == 42)
        #expect(conventions.images.altTextAverageLength.isOverridden == false)
    }

    @Test("merging(overriddenFrom:) preserves only the overridden fields from the previous value")
    func mergingPreservesOverriddenFieldsOnly() {
        var previous = ProjectConventions.empty
        previous.apply(.altTextAverageLength(42))
        previous.writing.brandTerms = Learned(value: ["Anglesite"], source: .inferred(confidence: 1), sampleSize: 3)

        var fresh = ProjectConventions.empty
        fresh.images.altTextAverageLength = Learned(value: 10, source: .inferred(confidence: 1), sampleSize: 5)
        fresh.writing.brandTerms = Learned(value: ["anglesite"], source: .inferred(confidence: 1), sampleSize: 5)

        let merged = fresh.merging(overriddenFrom: previous)

        // Overridden field survives the merge untouched.
        #expect(merged.images.altTextAverageLength.value == 42)
        #expect(merged.images.altTextAverageLength.isOverridden == true)
        // Non-overridden field takes the fresh (just-recomputed) value.
        #expect(merged.writing.brandTerms.value == ["anglesite"])
    }
}
