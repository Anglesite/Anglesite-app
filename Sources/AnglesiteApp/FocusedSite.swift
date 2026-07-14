import SwiftUI
import AppKit
import AnglesiteCore
import AnglesiteIntents

private struct FocusedSiteIDKey: FocusedValueKey { typealias Value = String }
private struct FocusedNewContentActionsKey: FocusedValueKey { typealias Value = NewContentActions }
private struct FocusedNavigatorSelectionActionsKey: FocusedValueKey { typealias Value = NavigatorSelectionActions }

struct NewContentActions {
    let newPage: @MainActor () -> Void
    let newCollection: @MainActor () -> Void
    let newPost: @MainActor () -> Void
    let newComponent: @MainActor () -> Void
}

/// Delete/Duplicate acting on the Navigator's current selection (#516). Each action is `nil` when
/// there is no selection, or the selection isn't a page/post (`SiteNavigatorModel.canDelete`/
/// `canDuplicate`) — that's what lets the Edit-menu items enable/disable correctly without the
/// menu needing to know Navigator internals.
struct NavigatorSelectionActions {
    let delete: (@MainActor () -> Void)?
    let duplicate: (@MainActor () -> Void)?
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

    var navigatorSelectionActions: NavigatorSelectionActions? {
        get { self[FocusedNavigatorSelectionActionsKey.self] }
        set { self[FocusedNavigatorSelectionActionsKey.self] = newValue }
    }
}

/// Must be `Commands` (not `App`) so the focused scene values can flow into the menu state.
struct NewContentCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    // SwiftUI exposes `.focusedSceneValue(...)` as the publishing modifier; command readers still
    // use `@FocusedValue`. There is no `@FocusedSceneValue` property wrapper in the macOS 27 SDK.
    @FocusedValue(\.newContentActions) private var focusedActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Site…") {
                openWindow(id: "sites")
                WindowRouter.shared.requestNewSite()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            // Temporary home — relocates to Insert ▸ Component when the Insert menu
            // lands (menu-bar spec §2.4).
            Button("New Component…") {
                focusedActions?.newComponent()
            }
            .disabled(focusedActions == nil)

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
            alert.messageText = String(localized: "Couldn't open that site")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

/// Edit ▸ Delete (⌘⌫) / Duplicate (⌘D) for the focused window's Navigator selection (#516).
/// Placed in the Edit menu next to Cut/Copy/Paste — the macOS convention for selection-scoped
/// destructive/duplicate actions — rather than the File menu.
struct NavigatorEditCommands: Commands {
    @FocusedValue(\.navigatorSelectionActions) private var actions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Delete") {
                actions?.delete?()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(actions?.delete == nil)

            Button("Duplicate") {
                actions?.duplicate?()
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(actions?.duplicate == nil)
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
