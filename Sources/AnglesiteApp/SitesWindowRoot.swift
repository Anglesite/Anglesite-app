import SwiftUI
import AnglesiteIntents

/// Root content for the "Sites" window. Wraps `SitesLauncherView` and bridges
/// `WindowRouter` requests (from `OpenSiteIntent`) to `openWindow(value:)`. Holding the router
/// as observed `@State` guarantees `.onChange` re-evaluates when an intent sets `requested`.
struct SitesWindowRoot: View {
    let openWindow: OpenWindowAction
    @State private var router = WindowRouter.shared

    var body: some View {
        SitesLauncherView()
            .onChange(of: router.requested) { _, newValue in
                guard let id = newValue else { return }
                openWindow(value: id)   // WindowGroup(for: String.self) focuses or opens the site
                router.requested = nil
            }
            .onAppear {
                // Stash a launcher-opener for AppKit callers (Dock menu, #522). OpenWindowAction
                // is scene-independent, so this stays valid after the launcher closes.
                let openWindow = openWindow
                router.openSitesWindow = { openWindow(id: "sites") }
            }
    }
}
