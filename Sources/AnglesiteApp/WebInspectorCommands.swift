import SwiftUI

private struct FocusedPreviewKey: FocusedValueKey { typealias Value = PreviewModel }

extension FocusedValues {
    /// The focused site window's `PreviewModel`, published by `SiteWindow`. Lets View-menu commands
    /// reach the live preview without owning it.
    var preview: PreviewModel? {
        get { self[FocusedPreviewKey.self] }
        set { self[FocusedPreviewKey.self] = newValue }
    }
}

/// "Show Web Inspector" in the View menu — opens the focused site window's preview inspector.
/// Enabled only when a site window is focused; a no-op until that window's dev server is ready and
/// the web view exists, and in MAS builds where the private WebKit open path compiles out.
struct WebInspectorCommands: Commands {
    @FocusedValue(\.preview) private var focusedPreview

    var body: some Commands {
        // Keep "Show Web Inspector" adjacent to "Show Debug Pane"; both are developer tools.
        CommandGroup(after: .toolbar) {
            Button("Show Web Inspector") {
                focusedPreview?.showWebInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(focusedPreview == nil)
        }
    }
}
