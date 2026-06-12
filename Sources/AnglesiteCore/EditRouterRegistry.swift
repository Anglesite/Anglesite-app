import Foundation

/// Per-siteID registry of live `EditRouter`s.
///
/// Each open `SiteWindow`'s `PreviewModel` registers its `editRouter` here under the site's id,
/// and `IntentEditBridge`'s `RouterProvider` reads it back when an intent (`EditContentIntent`,
/// B.5 / #149) needs to apply an edit. The registry lives in `AnglesiteCore` so both layers can
/// see it; `AnglesiteIntents` doesn't need to know about WKWebView or `PreviewModel`.
///
/// Single shared instance — `EditRouterRegistry.shared`. Routers are kept by strong reference
/// (the protocol isn't `AnyObject`-constrained so weak refs aren't expressible). The owner
/// (`PreviewModel`) is responsible for paired register/unregister around its lifecycle, exactly
/// like its existing `open()` / `close()` pair.
///
/// Last-writer-wins on duplicate siteID registration: opening the same site in a fresh window or
/// rewriting the router via `setEditObserver(_:)` overwrites the prior registration.
public actor EditRouterRegistry {
    public static let shared = EditRouterRegistry()

    private var routers: [String: EditRouter] = [:]

    public init() {}

    public func register(_ router: EditRouter, for siteID: String) {
        routers[siteID] = router
    }

    public func unregister(siteID: String) {
        routers.removeValue(forKey: siteID)
    }

    public func router(for siteID: String) -> EditRouter? {
        routers[siteID]
    }

    /// All currently-registered siteIDs. Surfaced for tests + diagnostics; production callers
    /// always know the siteID they're asking about.
    public func knownSiteIDs() -> Set<String> {
        Set(routers.keys)
    }
}
