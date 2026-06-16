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

    public func requestOpen(siteID: String) { requested = siteID }

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
