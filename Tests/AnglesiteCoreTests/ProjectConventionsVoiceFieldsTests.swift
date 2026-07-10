// Tests/AnglesiteCoreTests/ProjectConventionsVoiceFieldsTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ProjectConventionsVoiceFieldsTests {
    @Test func emptyHasUnsetVoiceFields() {
        let c = ProjectConventions.empty
        #expect(c.writing.audience.value == "")
        #expect(c.writing.avoidPhrases.value == [])
        #expect(!c.writing.audience.isOverridden)
    }

    @Test func applyOverridesVoiceFields() {
        var c = ProjectConventions.empty
        c.apply(.audience("busy parents in Oakland"))
        c.apply(.avoidPhrases(["synergy", "world-class"]))
        #expect(c.writing.audience.value == "busy parents in Oakland")
        #expect(c.writing.audience.isOverridden)
        #expect(c.writing.avoidPhrases.value == ["synergy", "world-class"])
    }

    @Test func mergingPreservesVoiceOverrides() {
        var previous = ProjectConventions.empty
        previous.apply(.audience("locals"))
        let fresh = ProjectConventions.empty
        let merged = fresh.merging(overriddenFrom: previous)
        #expect(merged.writing.audience.value == "locals")
        #expect(merged.writing.audience.isOverridden)
    }

    @Test func clearOverrideRevertsSource() {
        var c = ProjectConventions.empty
        c.apply(.audience("locals"))
        c.clearOverride(.audience)
        #expect(!c.writing.audience.isOverridden)
    }

    /// Old conventions.json files predate the two voice fields — they must decode with defaults.
    @Test func decodesLegacyJSONWithoutVoiceFields() throws {
        let legacy = """
        {"headingCapitalization":{"value":"mixed","source":{"inferred":{"confidence":0}},"sampleSize":0},
         "toneDescriptors":{"value":[],"source":{"inferred":{"confidence":0}},"sampleSize":0},
         "brandTerms":{"value":[],"source":{"inferred":{"confidence":0}},"sampleSize":0}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WritingConventions.self, from: legacy)
        #expect(decoded.audience.value == "")
        #expect(decoded.avoidPhrases.value == [])
    }
}
