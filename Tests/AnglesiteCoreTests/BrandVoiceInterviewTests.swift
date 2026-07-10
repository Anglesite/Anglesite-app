// Tests/AnglesiteCoreTests/BrandVoiceInterviewTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct BrandVoiceInterviewTests {
    @Test func appliesNonEmptyAnswersAsOverrides() {
        let answers = BrandVoiceAnswers(
            audience: "home bakers",
            toneWords: ["warm", "expert", "playful"],
            brandTerms: ["SourdoughLab"],
            avoidPhrases: ["artisanal"]
        )
        let c = BrandVoiceInterview.apply(answers, to: .empty)
        #expect(c.writing.audience.value == "home bakers")
        #expect(c.writing.audience.isOverridden)
        #expect(c.writing.toneDescriptors.value == ["warm", "expert", "playful"])
        #expect(c.writing.brandTerms.value == ["SourdoughLab"])
        #expect(c.writing.avoidPhrases.value == ["artisanal"])
    }

    /// Empty answers must not clobber existing (possibly inferred) values with empty overrides.
    @Test func emptyAnswersLeaveFieldsUntouched() {
        var existing = ProjectConventions.empty
        existing.writing.toneDescriptors = Learned(value: ["calm"], source: .inferred(confidence: 0.7), sampleSize: 9)
        let answers = BrandVoiceAnswers(audience: "", toneWords: [], brandTerms: [], avoidPhrases: [])
        let c = BrandVoiceInterview.apply(answers, to: existing)
        #expect(c.writing.toneDescriptors.value == ["calm"])
        #expect(!c.writing.toneDescriptors.isOverridden)
        #expect(c.writing.audience.value == "")
    }

    @Test func listSplitsAndTrims() {
        #expect(BrandVoiceInterview.list(" warm, expert ,playful ") == ["warm", "expert", "playful"])
        #expect(BrandVoiceInterview.list(nil) == [])
        #expect(BrandVoiceInterview.list("  ") == [])
    }
}
