import SwiftUI
import AnglesiteCore

/// The site shown by the currently-active window, published by `SiteWindow` via
/// `focusedSceneValue` so window-targeted File-menu commands (Export) can read it. Using SwiftUI's
/// focused-value system — rather than a mutable `focusedSite` on a shared singleton — means the menu
/// always reflects the active scene and auto-enables/disables with no manual focus bookkeeping.
struct FocusedSiteKey: FocusedValueKey {
    typealias Value = SiteStore.Site
}

extension FocusedValues {
    var focusedSite: SiteStore.Site? {
        get { self[FocusedSiteKey.self] }
        set { self[FocusedSiteKey.self] = newValue }
    }
}

/// File ▸ Export Site Source… — operates on the focused site window. Lives in its own `Commands`
/// type because reading `@FocusedValue` requires a `Commands`/`View` context (the inline
/// `.commands { … }` builder in `AnglesiteApp` can't hold property wrappers).
struct ExportSiteCommands: Commands {
    @FocusedValue(\.focusedSite) private var focusedSite

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export Site Source…") {
                if let focusedSite { SiteActions.exportSource(of: focusedSite) }
            }
            .disabled(focusedSite == nil)
        }
    }
}
