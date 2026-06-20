import Foundation
import Observation

/// Lets `OpenSiteIntent` (which can't call SwiftUI's `openWindow`) request a site window.
/// The "Sites" scene observes `requested` and opens/focuses the matching per-site window.
@MainActor
@Observable
public final class WindowRouter {
    public static let shared = WindowRouter()
    private init() {}

    /// The site id the intent asked to open; the scene clears it after handling.
    public var requested: String?

    /// Pending navigation per site, set with an open request and consumed once by that site's
    /// window — which observes `pendingNavigation` and clears its own entry, the same shape
    /// `newSiteRequested` uses below. It is *separate* from `requested` (the scene's open/focus
    /// trigger, which the scene clears before the window ever sees it) because a window already
    /// on screen must still react to a new page request. Keyed by siteID so one site's window
    /// can't pick up another's; re-requesting overwrites the pending value (last request wins).
    ///
    /// The value is itself optional: a route navigates there; `nil` resets the preview to the
    /// site root (a plain "preview my site" issued after a prior page navigation).
    public private(set) var pendingNavigation: [String: String?] = [:]

    public func requestOpen(siteID: String, route: String? = nil) {
        // `updateValue` (not `pendingNavigation[siteID] = route`) so a `nil` route records the
        // key with a nil value — "reset to root" — instead of removing the entry.
        pendingNavigation.updateValue(route, forKey: siteID)
        requested = siteID
    }

    /// Take (and clear) the pending navigation for `siteID`. Returns `.none` when nothing is
    /// pending, `.some(nil)` to reset to the site root, or `.some(route)` to navigate there.
    public func consumeNavigation(for siteID: String) -> String?? {
        pendingNavigation.removeValue(forKey: siteID)
    }

    /// Set by File ▸ New Site (which can't host the wizard sheet itself). The "Sites"
    /// launcher observes this, runs `presentNewSite()`, then clears it via
    /// `clearNewSiteRequest()`. `private(set)` so only the two methods below mutate it —
    /// external callers can't subvert the set-then-consume contract the launcher relies on.
    /// Mirrors `requested`/`requestOpen` for the open-existing path.
    public private(set) var newSiteRequested = false

    public func requestNewSite() { newSiteRequested = true }

    /// Called by the launcher once it has consumed the request.
    public func clearNewSiteRequest() { newSiteRequested = false }
}
