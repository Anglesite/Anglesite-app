// Darwin implementation of the SecurityScopedBookmark seam. The whole file compiles out on
// platforms without the App Sandbox's `.withSecurityScope` bookmark APIs (macOS-only —
// iOS Foundation has no `.withSecurityScope`, so iOS takes the Unavailable path).
#if os(macOS)
import Foundation

/// MAS-only at runtime: the sandboxed app persists one bookmark per site (on
/// `SiteStore.Site.bookmarkData`), resolves it at window-open time, and holds the grant via
/// `startAccessing` for the window's lifetime so the directly-spawned Node/Astro/wrangler
/// children inherit folder access. Nothing crosses a process boundary — the app is the sole
/// grant holder (see docs/specs/2026-05-27-sandboxed-app-store-plan.md, "ARCHITECTURE PIVOT").
public struct DarwinSecurityScopedBookmark: SecurityScopedBookmarking {
    public init() {}

    public func create(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw SecurityScopedBookmarkError.createFailed(error.localizedDescription)
        }
    }

    public func resolve(_ data: Data) throws -> SecurityScopedBookmarkResolution {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return SecurityScopedBookmarkResolution(url: url, isStale: isStale)
        } catch {
            throw SecurityScopedBookmarkError.resolveFailed(error.localizedDescription)
        }
    }

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
#endif
