import Foundation
import Observation
import AnglesiteCore

/// Synchronous, live-updating mirror of the site registry for the File ▸ Open Recent submenu.
///
/// SwiftUI menus can't `await`, but `SiteStore` is an `actor`. This `@MainActor @Observable`
/// holds the current selection so the menu reads it synchronously, and stays current by
/// consuming `SiteStore.changeStream()` (the #188 broadcast), shaping each snapshot through
/// `RecentSites.select`.
@MainActor
@Observable
final class RecentSitesModel {
    static let shared = RecentSitesModel()
    private init() {}

    /// Most-recent-first, capped. Drives the Open Recent submenu.
    private(set) var sites: [SiteStore.Site] = []

    private var started = false

    /// Begin mirroring the registry. Idempotent — safe to call once at launch.
    func start() {
        guard !started else { return }
        started = true
        Task {
            // Populate from disk + scan first so the menu is correct before any mutation.
            do {
                try await SiteStore.shared.load()
                let scanned = try await SiteStore.shared.refresh()
                sites = RecentSites.select(from: scanned)
            } catch {
                await LogCenter.shared.append(source: "recent-sites", stream: .stderr, text: "initial load failed: \(error)")
            }
            // Then track every mutation. `changeStream()` also re-emits the current snapshot
            // on subscribe, which simply reaffirms what we just set.
            for await snapshot in SiteStore.shared.changeStream() {
                sites = RecentSites.select(from: snapshot)
            }
        }
    }
}
