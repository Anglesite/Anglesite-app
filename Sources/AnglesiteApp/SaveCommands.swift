import SwiftUI

private struct FocusedSiteWindowModelKey: FocusedValueKey { typealias Value = SiteWindowModel }

extension FocusedValues {
    /// The focused site window's `SiteWindowModel`, published by `SiteWindow`. Lets menu commands
    /// reach the window's editing surfaces (and, later, its site operations — #511) without
    /// owning them.
    var siteWindowModel: SiteWindowModel? {
        get { self[FocusedSiteWindowModelKey.self] }
        set { self[FocusedSiteWindowModelKey.self] = newValue }
    }
}

/// File ▸ Save / Revert to Saved for the focused site window's editing surfaces (main-pane editor
/// and inspector). Replaces the hidden per-view ⌘S buttons, which double-registered the shortcut
/// whenever the editor and inspector were both on screen (#509).
struct SaveCommands: Commands {
    // SwiftUI exposes `.focusedSceneValue(...)` as the publishing modifier; command readers still
    // use `@FocusedValue`. There is no `@FocusedSceneValue` property wrapper in the macOS 27 SDK.
    @FocusedValue(\.siteWindowModel) private var siteWindowModel

    var body: some Commands {
        // Anchored to .importExport, not .saveItem: in a non-DocumentGroup app the .saveItem
        // placement is dead — both `replacing:` and `after:` render nothing (verified empirically
        // on the macOS 27 SDK). .importExport demonstrably works (ExportSiteCommands), and
        // `before:` puts Save/Revert between Close and Export Site Source…, matching the
        // File-menu order of Apple's document apps.
        CommandGroup(before: .importExport) {
            Button("Save") {
                guard let model = siteWindowModel else { return }
                Task { await model.saveAllEdits() }
            }
            .keyboardShortcut("s")
            .disabled(siteWindowModel?.hasUnsavedEdits != true)

            Button("Revert to Saved") {
                siteWindowModel?.requestRevertToSaved()
            }
            .disabled(siteWindowModel?.hasUnsavedEdits != true)
        }
    }
}
