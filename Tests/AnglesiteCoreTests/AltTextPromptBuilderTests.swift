import Testing
@testable import AnglesiteCore

@Suite("AltTextPromptBuilder")
struct AltTextPromptBuilderTests {
    @Test("returns the base prompt unchanged when there are no learned conventions")
    func returnsBasePromptWhenNoConventions() {
        let prompt = AltTextPromptBuilder.build(basePrompt: "Generate alt text.", conventions: nil)
        #expect(prompt == "Generate alt text.")
    }

    @Test("returns the base prompt unchanged when conventions have no signal yet")
    func returnsBasePromptWhenEmpty() {
        let prompt = AltTextPromptBuilder.build(basePrompt: "Generate alt text.", conventions: .empty)
        #expect(prompt == "Generate alt text.")
    }

    @Test("appends a guidance preamble drawn from images and brand-term conventions")
    func appendsGuidancePreamble() {
        var conventions = ProjectConventions.empty
        conventions.images.altTextAverageLength = Learned(value: 60, source: .inferred(confidence: 1), sampleSize: 10)
        conventions.images.altTextEndsWithPunctuation = Learned(value: true, source: .inferred(confidence: 1), sampleSize: 10)
        conventions.writing.brandTerms = Learned(value: ["Anglesite", "Astro"], source: .inferred(confidence: 1), sampleSize: 10)

        let prompt = AltTextPromptBuilder.build(basePrompt: "Generate alt text.", conventions: conventions)

        #expect(prompt.contains("Generate alt text."))
        #expect(prompt.contains("60 characters"))
        #expect(prompt.contains("ending with punctuation"))
        #expect(prompt.contains("Anglesite"))
        #expect(prompt.contains("Astro"))
    }

    @Test("an overridden image field is included even with a nil sampleSize")
    func includesOverriddenFieldWithNilSampleSize() {
        var conventions = ProjectConventions.empty
        conventions.apply(.altTextAverageLength(42))
        conventions.apply(.altTextEndsWithPunctuation(true))

        let prompt = AltTextPromptBuilder.build(basePrompt: "Generate alt text.", conventions: conventions)

        #expect(prompt.contains("42 characters"))
        #expect(prompt.contains("ending with punctuation"))
    }
}
