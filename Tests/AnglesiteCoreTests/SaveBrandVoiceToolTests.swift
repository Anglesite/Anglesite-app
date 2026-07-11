import Testing
@testable import AnglesiteCore

@Suite struct SaveBrandVoiceToolTests {
    @Test func confirmationNamesWhatWasSaved() {
        let answers = BrandVoiceAnswers(
            audience: "home bakers", toneWords: ["warm"], brandTerms: [], avoidPhrases: ["cheap"])
        let reply = SaveBrandVoiceReply.confirmation(for: answers)
        #expect(reply.contains("audience"))
        #expect(reply.contains("tone"))
        #expect(reply.contains("phrases to avoid"))
        #expect(!reply.contains("brand terms"))
    }

    @Test func emptyAnswersYieldNothingSavedReply() {
        let answers = BrandVoiceAnswers(audience: "", toneWords: [], brandTerms: [], avoidPhrases: [])
        #expect(SaveBrandVoiceReply.confirmation(for: answers).contains("didn't save"))
    }
}
