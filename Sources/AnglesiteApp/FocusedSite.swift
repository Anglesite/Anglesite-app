import SwiftUI
import AnglesiteCore

private struct FocusedSiteIDKey: FocusedValueKey { typealias Value = String }

extension FocusedValues {
    var siteID: String? {
        get { self[FocusedSiteIDKey.self] }
        set { self[FocusedSiteIDKey.self] = newValue }
    }
}

/// File ▸ Export Site Source… — targets the focused site window. This MUST live in a `Commands`
/// type, not in the `App` struct: `@FocusedValue` only tracks scene focus inside a `View`/`Commands`
/// graph node, so a copy declared on `App` (whose body returns a `Scene`) stays permanently `nil`
/// and leaves the menu item disabled forever. `SiteWindow` publishes the id via `.focusedValue(\.siteID, …)`.
struct ExportSiteCommands: Commands {
    @FocusedValue(\.siteID) private var focusedSiteID

    var body: some Commands {
        // Export lives after the standard Save items. Enabled only when a site window is focused.
        CommandGroup(after: .importExport) {
            Button("Export Site Source…") {
                // Capture the focused id at press time — reading it inside the Task would resolve it
                // at execution time, so a focus shift between click and dispatch could export the
                // wrong window.
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
