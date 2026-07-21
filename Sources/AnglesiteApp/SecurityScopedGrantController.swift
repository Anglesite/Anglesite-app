#if ANGLESITE_MAS
import Foundation
import AnglesiteCore

/// Holds the security-scoped bookmark grant for one open site window's package, under App
/// Sandbox / Mac App Store distribution (#242). Extracted from `SiteWindowModel.acquireGrant`
/// (#822) as one of its four embedded subsystems.
///
/// One instance per `SiteWindowModel`, reused across window replay (a `WindowGroup` restoring a
/// different site into the same view instance) — `acquireGrant` releases any prior grant before
/// resolving the new one.
@MainActor
final class SecurityScopedGrantController {
    private(set) var scopedURL: URL?

    init() {}

    /// Resolve the site's persisted security-scoped bookmark and hold the grant for the window's
    /// lifetime. Must run before any subprocess spawn so direct children inherit folder access.
    /// On a stale bookmark, re-mint and persist a fresh one (grant must be active to do so).
    func acquireGrant(for site: SiteStore.Site, in store: SiteStore) async {
        // Release any prior grant first (window replay into the same instance): the window now
        // shows a different site, so keeping the old grant — even on the failure paths below — leaks.
        if let previous = scopedURL {
            previous.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
        guard let bookmark = await store.bookmarkData(for: site.id) else {
            await LogCenter.shared.append(
                source: "grant:\(site.id)", stream: .stderr,
                text: "No security-scoped bookmark for \(site.name); preview will fail until the package is re-added via Open Site…"
            )
            return
        }
        do {
            let resolved = try SecurityScopedBookmark.resolve(bookmark)
            guard resolved.url.startAccessingSecurityScopedResource() else {
                await LogCenter.shared.append(
                    source: "grant:\(site.id)", stream: .stderr,
                    text: "startAccessingSecurityScopedResource() returned false for \(resolved.url.path)"
                )
                return
            }
            scopedURL = resolved.url
            if resolved.isStale, let fresh = try? SecurityScopedBookmark.create(for: resolved.url) {
                try? await store.setBookmark(fresh, for: site.id)
            }
        } catch {
            await LogCenter.shared.append(
                source: "grant:\(site.id)", stream: .stderr,
                text: "Couldn't resolve security-scoped bookmark for \(site.name): \(error)"
            )
        }
    }

    /// Clears the held grant and returns the URL that was released, if any — the caller (window
    /// close) is responsible for actually calling `stopAccessingSecurityScopedResource()` on it,
    /// deferred until any pending editor/inspector save tasks finish (they may still need the
    /// scope active). Mirrors `SiteWindowModel.close()`'s existing ordering.
    func release() -> URL? {
        defer { scopedURL = nil }
        return scopedURL
    }
}
#endif
