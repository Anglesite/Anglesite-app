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

    /// Pending page route per site, set alongside an open request and consumed once by the
    /// site's window. Keyed by siteID so one site's window can't pick up another's route.
    /// Re-requesting a site overwrites any still-pending route (last request wins).
    private var pendingRoute: [String: String] = [:]

    public func requestOpen(siteID: String, route: String? = nil) {
        requested = siteID
        if let route { pendingRoute[siteID] = route }
    }

    /// Take (and clear) the route requested for `siteID`, if any. Returns `nil` after the first
    /// read or when no route was requested.
    public func consumeRoute(for siteID: String) -> String? {
        pendingRoute.removeValue(forKey: siteID)
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
