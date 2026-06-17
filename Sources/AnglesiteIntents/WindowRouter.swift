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
}
