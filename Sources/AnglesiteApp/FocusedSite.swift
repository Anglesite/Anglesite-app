import SwiftUI
import AnglesiteCore

private struct FocusedSiteIDKey: FocusedValueKey { typealias Value = String }

extension FocusedValues {
    var siteID: String? {
        get { self[FocusedSiteIDKey.self] }
        set { self[FocusedSiteIDKey.self] = newValue }
    }
}

private struct FocusedPreviewKey: FocusedValueKey { typealias Value = PreviewModel }

extension FocusedValues {
    /// The focused site window's `PreviewModel`, published by `SiteWindow`. Lets View-menu commands
    /// (e.g. `WebInspectorCommands`) reach the live preview without owning it.
    var preview: PreviewModel? {
        get { self[FocusedPreviewKey.self] }
        set { self[FocusedPreviewKey.self] = newValue }
    }
}

/// Must be `Commands` (not `App`) — `@FocusedValue` only tracks scene focus inside a `View`/`Commands` node.
struct ExportSiteCommands: Commands {
    @FocusedValue(\.siteID) private var focusedSiteID

    var body: some Commands {
        // Export lives after the standard Save items. Enabled only when a site window is focused.
        CommandGroup(after: .importExport) {
            Button("Export Site Source…") {
                // Capture now — focus may shift between press and Task execution.
                guard let id = focusedSiteID else { return }
                Task { @MainActor in
                    if let site = await SiteStore.shared.find(id: id) {
                        SiteActions.exportSource(of: site)
                    }
                }
            }
            .disabled(focusedSiteID == nil)
        }
    }
}

/// "Show Web Inspector" in the View menu — opens the focused site window's preview inspector
/// (control-click already exposes WebKit's native "Inspect Element"). Enabled only when a site
/// window is focused; a no-op until that window's dev server is ready and the web view exists.
struct WebInspectorCommands: Commands {
    @FocusedValue(\.preview) private var focusedPreview

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Show Web Inspector") {
                focusedPreview?.showWebInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(focusedPreview == nil)
        }
    }
}
