import Foundation

/// Create/resolve wrapper around `URL.bookmarkData(options: .withSecurityScope, ...)`.
///
/// MAS-only at runtime: the sandboxed app persists one bookmark per site (on
/// `SiteStore.Site.bookmarkData`), resolves it at window-open time, and holds the grant via
/// `startAccessingSecurityScopedResource()` for the window's lifetime so the directly-spawned
/// Node/Astro/wrangler children inherit folder access. Nothing crosses a process boundary —
/// the app is the sole grant holder (see docs/specs/2026-05-27-sandboxed-app-store-plan.md,
/// "ARCHITECTURE PIVOT").
public enum SecurityScopedBookmark {
    public struct Resolved: Sendable, Equatable {
        public let url: URL
        public let isStale: Bool
    }

    public enum BookmarkError: Error, Sendable {
        case createFailed(String)
        case resolveFailed(String)
    }

    /// Create a security-scoped bookmark for `url`. The caller must have access at create time
    /// (typically: the URL just returned from `NSOpenPanel`).
    public static func create(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BookmarkError.createFailed(error.localizedDescription)
        }
    }

    /// Resolve a previously-created bookmark. The caller must
    /// `startAccessingSecurityScopedResource()` on the returned URL before use and
    /// `stopAccessingSecurityScopedResource()` when done. A `true` `isStale` means the caller
    /// should re-`create` a fresh bookmark (after starting access) and persist it.
    public static func resolve(_ data: Data) throws -> Resolved {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return Resolved(url: url, isStale: isStale)
        } catch {
            throw BookmarkError.resolveFailed(error.localizedDescription)
        }
    }
}
