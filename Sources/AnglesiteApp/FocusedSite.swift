import SwiftUI
import AppKit
import AnglesiteCore
import AnglesiteIntents

private struct FocusedSiteIDKey: FocusedValueKey { typealias Value = String }
private struct FocusedNewContentActionsKey: FocusedValueKey { typealias Value = NewContentActions }

struct NewContentActions {
    let newPage: @MainActor () -> Void
    let newCollection: @MainActor () -> Void
}

extension FocusedValues {
    var siteID: String? {
        get { self[FocusedSiteIDKey.self] }
        set { self[FocusedSiteIDKey.self] = newValue }
    }

    var newContentActions: NewContentActions? {
        get { self[FocusedNewContentActionsKey.self] }
        set { self[FocusedNewContentActionsKey.self] = newValue }
    }
}

/// Must be `Commands` (not `App`) — `@FocusedValue` only tracks scene focus inside a `View`/`Commands` node.
struct NewContentCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.newContentActions) private var focusedActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Menu("New") {
                Button("Site") {
                    openWindow(id: "sites")
                    WindowRouter.shared.requestNewSite()
                }
                .keyboardShortcut("n")

                Button("Page…") {
                    focusedActions?.newPage()
                }
                .disabled(focusedActions == nil)

                Button("Collection…") {
                    focusedActions?.newCollection()
                }
                .disabled(focusedActions == nil)
            }

            Button("Open Site…") {
                Task { await openSiteFromMenu() }
            }
            .keyboardShortcut("o")
        }
    }

    @MainActor
    private func openSiteFromMenu() async {
        do {
            guard let site = try await SiteActions.pickAndRegisterSite() else { return }
            openWindow(value: site.id)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open that site"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
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
