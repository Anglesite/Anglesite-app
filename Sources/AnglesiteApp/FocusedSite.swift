import SwiftUI
import AnglesiteCore

private struct FocusedSiteIDKey: FocusedValueKey { typealias Value = String }

extension FocusedValues {
    var siteID: String? {
        get { self[FocusedSiteIDKey.self] }
        set { self[FocusedSiteIDKey.self] = newValue }
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
