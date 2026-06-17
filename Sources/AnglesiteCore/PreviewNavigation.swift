import Foundation

/// Composes the URL the live-preview WKWebView should load when a page route is requested
/// (e.g. by `PreviewSiteIntent`). Pure and `AnglesiteCore`-scoped so it's unit-testable on CI —
/// the App-target glue that calls it (`PreviewModel`) is not.
public enum PreviewNavigation {
    /// The absolute preview URL for `route` against the dev-server `base`.
    /// `route` is treated as a site-absolute path; `base`'s scheme/host/port are preserved.
    /// An empty route or `"/"` returns `base` (the site root).
    public static func targetURL(base: URL, route: String) -> URL {
        let trimmed = route.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return base }
        let path = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        comps.path = path
        return comps.url ?? base
    }
}
