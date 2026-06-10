import Foundation
import Observation
import SwiftUI

/// Lets `OpenSiteIntent` (which can't call SwiftUI's `openWindow`) request a site window.
/// The "Sites" scene observes `requested` and opens/focuses the matching per-site window.
@MainActor
@Observable
final class WindowRouter {
    static let shared = WindowRouter()
    private init() {}

    /// The site id the intent asked to open; the scene clears it after handling.
    var requested: String?

    func requestOpen(siteID: String) { requested = siteID }
}

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
    }
}
