import Foundation

/// Grants folder access around a single unit of work for a site, then releases it.
///
/// - DevID (non-sandboxed): passes `site.path` straight through.
/// - MAS (`ANGLESITE_MAS`): resolves the site's persisted security-scoped bookmark
///   (`SiteStore.bookmarkData`), holds the grant for the duration of `body`, then stops.
///   Mirrors `SiteWindow.acquireGrant` but short-lived, so background App Intents work with
///   no window open. Throws `AccessError.noGrant` if the site has no usable bookmark.
public enum SiteAccess {
    public enum AccessError: Error, Sendable, Equatable {
        /// No security-scoped bookmark for this site (MAS only). Carries a user-facing message.
        case noGrant(String)
    }

    /// Run `body` with read/write access to the site's directory. The returned URL is the
    /// directory `body` should operate in (`site.path` on DevID, the bookmark-resolved URL
    /// on MAS — they're the same path, but the MAS URL carries the active security scope).
    public static func withScopedAccess<T: Sendable>(
        to site: SiteStore.Site,
        in store: SiteStore = .shared,
        _ body: (URL) async -> T
    ) async throws -> T {
        #if ANGLESITE_MAS
        guard let data = await store.bookmarkData(for: site.id) else {
            throw AccessError.noGrant(
                "\(site.name) has no folder grant. Open it once via Open Folder… in Anglesite, then try again."
            )
        }
        let resolved = try SecurityScopedBookmark.resolve(data)
        guard resolved.url.startAccessingSecurityScopedResource() else {
            throw AccessError.noGrant(
                "Couldn't access \(site.name)'s folder. Re-add it via Open Folder… in Anglesite."
            )
        }
        defer { resolved.url.stopAccessingSecurityScopedResource() }
        // A stale bookmark still resolves; re-mint while the grant is active so it survives.
        if resolved.isStale, let fresh = try? SecurityScopedBookmark.create(for: resolved.url) {
            try? await store.setBookmark(fresh, for: site.id)
        }
        return await body(resolved.url)
        #else
        return await body(site.path)
        #endif
    }
}
