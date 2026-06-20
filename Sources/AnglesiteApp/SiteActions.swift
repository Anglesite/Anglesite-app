import AppKit
import UniformTypeIdentifiers
import AnglesiteCore

/// File-menu / launcher actions that are window-independent. Today this is just the
/// “open an existing package as a site” flow, extracted from `SitesLauncherView.openFolder()`
/// so the File ▸ Open Site… command and the launcher footer share one implementation —
/// in particular the MAS security-scoped-bookmark minting, which must live in exactly one place.
@MainActor
enum SiteActions {
    /// Surfaced when registering a chosen package fails. Carries the package name so callers
    /// get a readable, location-specific message via `localizedDescription` — the regression
    /// that motivated this was a generic “couldn't add the chosen folder” that dropped the name.
    struct ImportError: LocalizedError {
        let folderName: String
        let underlying: Error
        var errorDescription: String? {
            "Couldn't add “\(folderName)”: \(underlying.localizedDescription)"
        }
    }

    /// Pick a plain Anglesite directory, choose where to save the new package, copy it in, and
    /// register the package. Returns the new site, or nil if either panel was cancelled.
    static func importPackage() async throws -> SiteStore.Site? {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "Choose"
        picker.message = "Choose an existing Anglesite site folder to import."
        guard picker.runModal() == .OK, let sourceDir = picker.url else { return nil }

        let name = sourceDir.deletingPathExtension().lastPathComponent
        let save = NSSavePanel()
        save.message = "Save the imported site package."
        save.nameFieldStringValue = "\(name).anglesite"
        save.directoryURL = AppSettings.shared.sitesRoot
        guard save.runModal() == .OK, let dest = save.url else { return nil }

        do {
            let pkg = try PackageTransfer.importDirectory(sourceDir, toPackageAt: dest, displayName: name)
            let site = try await SiteStore.shared.record(pkg)
            #if ANGLESITE_MAS
            // Propagate (don't swallow with try?) — a grantless imported site silently fails to
            // preview at open. Matches pickAndRegisterSite; mint from the canonicalized packageURL.
            let bm = try SecurityScopedBookmark.create(for: site.packageURL)
            try await SiteStore.shared.setBookmark(bm, for: site.id)
            #endif
            return site
        } catch {
            throw ImportError(folderName: sourceDir.lastPathComponent, underlying: error)
        }
    }

    /// Export the given site's source tree to a chosen folder.
    static func exportSource(of site: SiteStore.Site, includeGit: Bool) {
        let save = NSSavePanel()
        save.message = "Export this site's source files to a folder."
        save.nameFieldStringValue = site.name
        guard save.runModal() == .OK, let dest = save.url else { return }
        do {
            try PackageTransfer.exportSource(of: AnglesitePackage(url: site.packageURL), to: dest, includeGit: includeGit)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Run the package picker, register the chosen `.anglesite` package with `SiteStore`, and
    /// (on MAS) mint + persist a security-scoped bookmark so the grant survives relaunch.
    ///
    /// - Returns: the newly registered site, or `nil` if the user cancelled the panel.
    /// - Throws: `ImportError` (naming the chosen package) if registration or bookmarking fails.
    static func pickAndRegisterSite() async throws -> SiteStore.Site? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.anglesiteSite]
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an Anglesite site package."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let package = AnglesitePackage(url: url)
            let site = try await SiteStore.shared.record(package)
            #if ANGLESITE_MAS
            // The panel grant is the only chance to mint a scoped bookmark — persist it now so
            // the grant survives relaunch. Mint from `site.packageURL` (the canonicalized path the
            // store recorded), so the bookmark's path matches what subprocesses are spawned against.
            let bookmark = try SecurityScopedBookmark.create(for: site.packageURL)
            try await SiteStore.shared.setBookmark(bookmark, for: site.id)
            #endif
            return site
        } catch {
            throw ImportError(folderName: url.lastPathComponent, underlying: error)
        }
    }
}
