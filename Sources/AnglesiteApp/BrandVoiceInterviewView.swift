import SwiftUI
import AnglesiteCore

/// The 5-question brand-voice interview as a form (#465). Writes `.userOverride` entries via
/// `model.applyBrandVoice(_:)`, which goes through the same `ProjectConventionsEngine` +
/// `ProjectConventionsStore` the Style Guide inspector's per-field rows use, so this sheet's
/// answers show up there immediately rather than only on the next reload.
struct BrandVoiceInterviewView: View {
    let model: ProjectConventionsModel
    @Environment(\.dismiss) private var dismiss

    @State private var audience = ""
    @State private var toneWords = ""
    @State private var brandTerms = ""
    @State private var avoidPhrases = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brand Voice").font(.title2.bold())
            Text("A few questions so copy suggestions sound like you. Leave anything blank to skip it.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Who does this site speak to?", text: $audience, prompt: Text("e.g. busy parents in Oakland"))
                TextField("Three personality words", text: $toneWords, prompt: Text("e.g. warm, expert, playful"))
                TextField("Brand terms (exact capitalization)", text: $brandTerms, prompt: Text("e.g. SourdoughLab"))
                TextField("Words or phrases to avoid", text: $avoidPhrases, prompt: Text("e.g. artisanal, world-class"))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Voice") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(answers.audience.isEmpty && answers.toneWords.isEmpty
                              && answers.brandTerms.isEmpty && answers.avoidPhrases.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 360)
    }

    private var answers: BrandVoiceAnswers {
        BrandVoiceAnswers(
            audience: audience.trimmingCharacters(in: .whitespacesAndNewlines),
            toneWords: BrandVoiceInterview.list(toneWords),
            brandTerms: BrandVoiceInterview.list(brandTerms),
            avoidPhrases: BrandVoiceInterview.list(avoidPhrases)
        )
    }

    private func save() async {
        await model.applyBrandVoice(answers)
        dismiss()
    }
}
