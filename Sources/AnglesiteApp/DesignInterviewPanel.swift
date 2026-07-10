// Sources/AnglesiteApp/DesignInterviewPanel.swift
import SwiftUI
import AnglesiteCore

/// SwiftUI mirror of the `anglesite:design-interview` skill's conversation: a transcript column on
/// the left, live axis sliders + apply confirmation on the right. Mutations to `draft.axes` route
/// through `DesignInterviewModel.axisBinding(_:)` rather than `$model.draft.axes...` directly,
/// since `draft`'s setter is `internal(set)` to AnglesiteCore.
struct DesignInterviewPanel: View {
    @Bindable var model: DesignInterviewModel
    @State private var draftMessage = ""

    var body: some View {
        HSplitView {
            transcriptColumn
            axesColumn
        }
    }

    private var transcriptColumn: some View {
        VStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.transcript.enumerated()), id: \.offset) { _, entry in
                        transcriptBubble(entry)
                    }
                }
                .padding()
            }
            HStack {
                TextField("Describe what you're going for…", text: $draftMessage)
                    .onSubmit { Task { await sendDraft() } }
                Button("Send") { Task { await sendDraft() } }
                    .disabled(draftMessage.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 320)
    }

    private func transcriptBubble(_ entry: (role: String, text: String)) -> some View {
        let isUser = entry.role == "user"
        return Text(entry.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isUser ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
            )
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var axesColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Design Axes").font(.headline)
            axisSlider("Cool", "Warm", value: model.axisBinding(\.temperature))
            axisSlider("Airy", "Dense", value: model.axisBinding(\.weight))
            axisSlider("Playful", "Authoritative", value: model.axisBinding(\.register))
            axisSlider("Classic", "Contemporary", value: model.axisBinding(\.time))
            axisSlider("Subtle", "Bold", value: model.axisBinding(\.voice))

            Spacer()

            if model.draft.stage != .axisConfirmation && model.draft.stage != .done {
                Button("Design It For Me") { model.skipToAxisConfirmation() }
            }

            if model.draft.stage == .axisConfirmation {
                Button("Apply This Design") { Task { await model.confirmAndApply() } }
                    .buttonStyle(.borderedProminent)
            }

            applyResultView
        }
        .padding()
        .frame(minWidth: 260)
    }

    @ViewBuilder
    private var applyResultView: some View {
        switch model.applyResult {
        case .none:
            EmptyView()
        case .success:
            Label("Applied.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let error):
            Label("Couldn't apply that design: \(String(describing: error))", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func axisSlider(_ low: String, _ high: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(low).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(high).font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
        }
    }

    private func sendDraft() async {
        guard !draftMessage.isEmpty else { return }
        let message = draftMessage
        draftMessage = ""
        await model.send(message)
    }
}
