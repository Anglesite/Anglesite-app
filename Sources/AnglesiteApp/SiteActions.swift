import AppKit
import AnglesiteCore

/// File-menu / launcher actions that are window-independent. Today this is just the
/// "open an existing folder as a site" flow, extracted from `SitesLauncherView.openFolder()`
/// so the File ▸ Open Site… command and the launcher footer share one implementation —
/// in particular the MAS security-scoped-bookmark minting, which must live in exactly one place.
@MainActor
enum SiteActions {
    /// Surfaced when registering a chosen folder fails. Carries the folder name so callers
    /// get a readable, location-specific message via `localizedDescription` — the regression
    /// that motivated this was a generic "couldn't add the chosen folder" that dropped the name.
    struct ImportError: LocalizedError {
        let folderName: String
        let underlying: Error
        var errorDescription: String? {
            "Couldn't add “\(folderName)”: \(underlying.localizedDescription)"
        }
    }

    /// Run the folder picker, register the chosen project with `SiteStore`, and (on MAS)
    /// mint + persist a security-scoped bookmark so the grant survives relaunch.
    ///
    /// - Returns: the newly registered site, or `nil` if the user cancelled the panel.
    /// - Throws: `ImportError` (naming the chosen folder) if registration or bookmarking fails.
    static func pickAndRegisterSite() async throws -> SiteStore.Site? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an Anglesite project directory."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let site = try await SiteStore.shared.add(url)
            #if ANGLESITE_MAS
            // The panel grant is the only chance to mint a scoped bookmark — persist it now so
            // the grant survives relaunch. SiteWindow resolves it and holds access.
            let bookmark = try SecurityScopedBookmark.create(for: url)
            try await SiteStore.shared.setBookmark(bookmark, for: site.id)
            #endif
            return site
        } catch {
            throw ImportError(folderName: url.lastPathComponent, underlying: error)
        }
    }
}
