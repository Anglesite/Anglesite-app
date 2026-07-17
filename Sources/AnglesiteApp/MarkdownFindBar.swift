import SwiftUI

/// Find / replace bar shown above a `MarkdownTextView` (#517 Edit ▸ Find). Pure chrome: match
/// highlighting, navigation, and replacement all execute inside the engine via the controller's
/// bus; this view renders state and forwards intents.
struct MarkdownFindBar: View {
    @Bindable var controller: MarkdownEditorController
    @FocusState private var findFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Find", text: $controller.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($findFieldFocused)
                    .frame(maxWidth: 320)
                    .onSubmit { controller.findNext() }
                Text(matchCountLabel)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                ControlGroup {
                    Button { controller.findPrevious() } label: { Image(systemName: "chevron.left") }
                        .help("Find Previous")
                    Button { controller.findNext() } label: { Image(systemName: "chevron.right") }
                        .help("Find Next")
                }
                .disabled(controller.matchCount == 0)
                .frame(width: 72)
                Spacer()
                Toggle("Replace", isOn: $controller.showsReplace)
                    .toggleStyle(.checkbox)
                Button("Done") { controller.hideFind() }
            }
            if controller.showsReplace {
                HStack(spacing: 8) {
                    TextField("Replace With", text: $controller.replacement)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Button("Replace") { controller.replaceCurrentMatch() }
                        .disabled(controller.matchCount == 0)
                    Button("Replace All") { controller.replaceAllMatches() }
                        .disabled(controller.matchCount == 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { findFieldFocused = true }
        // The find bar sits OUTSIDE the engine's focus-tracking container, so gaining field focus
        // would otherwise read as "editor lost focus" and disable Find Next/Format mid-search.
        .onChange(of: findFieldFocused) { _, focused in
            if focused { MarkdownEditorFocusRegistry.shared.activate(controller) }
        }
        .onChange(of: controller.query) { controller.queryChanged() }
        .onExitCommand { controller.hideFind() }
    }

    private var matchCountLabel: String {
        if controller.query.isEmpty { return "" }
        if controller.matchCount == 0 { return String(localized: "No matches") }
        return String(localized: "\(controller.currentMatchIndex + 1) of \(controller.matchCount)")
    }
}
