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
            String(localized: "Couldn't add “\(folderName)”: \(underlying.localizedDescription)")
        }
    }

    /// Register an existing `.anglesite` package and (on MAS) mint its security-scoped bookmark —
    /// the ONLY mint call site, shared by every open path: Finder-open (`onOpenURL`), launcher
    /// drag-drop (#524), the Dock menu, File ▸ Open Site… (`pickAndRegisterSite`), and Import
    /// (`importPackage`). `record` reads and validates the marker, throwing a legible error for
    /// non-packages.
    static func registerPackage(at url: URL) async throws -> SiteStore.Site {
        try await registerPackage(AnglesitePackage(url: url))
    }

    /// Variant for callers that already hold a constructed package (Import creates one via
    /// `PackageTransfer` before registering).
    static func registerPackage(_ package: AnglesitePackage) async throws -> SiteStore.Site {
        let site = try await SiteStore.shared.record(package)
        #if ANGLESITE_MAS
        // The current access grant (open panel, drag, or LaunchServices open) is the only chance
        // to mint a scoped bookmark — persist it now so the grant survives relaunch. Mint from
        // `site.packageURL` (the canonicalized path the store recorded) so the bookmark's path
        // matches what subprocesses are spawned against. Propagate failures (never `try?`): a
        // grantless site silently fails to preview at open.
        let bookmark = try SecurityScopedBookmark.create(for: site.packageURL)
        try await SiteStore.shared.setBookmark(bookmark, for: site.id)
        #endif
        return site
    }

    /// Pick a plain Anglesite directory, choose where to save the new package, copy it in, and
    /// register the package. Returns the new site, or nil if either panel was cancelled.
    static func importPackage() async throws -> SiteStore.Site? {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = String(localized: "Choose")
        picker.message = String(localized: "Choose an existing Anglesite site folder to import.")
        guard picker.runModal() == .OK, let sourceDir = picker.url else { return nil }

        let name = sourceDir.deletingPathExtension().lastPathComponent
        let save = NSSavePanel()
        save.message = String(localized: "Save the imported site package.")
        save.nameFieldStringValue = "\(name).anglesite"
        save.directoryURL = AppSettings.shared.sitesRoot
        guard save.runModal() == .OK, let dest = save.url else { return nil }

        // The tree copy can be large (it may include node_modules) — run it off the main actor so
        // the import doesn't stall the UI. On failure after the copy created the package, clean up
        // the orphan; a `destinationExists` throw comes from importDirectory itself (before it
        // creates anything), so it lands in the outer catch and never deletes a pre-existing dir.
        let pkg: AnglesitePackage
        do {
            pkg = try await Task.detached {
                try PackageTransfer.importDirectory(sourceDir, toPackageAt: dest, displayName: name)
            }.value
        } catch {
            throw ImportError(folderName: sourceDir.lastPathComponent, underlying: error)
        }
        do {
            return try await registerPackage(pkg)
        } catch {
            // record/bookmark failed after importDirectory wrote the package — remove the orphan
            // (we created it this call) so it isn't left invisible-and-unopenable on disk.
            try? FileManager.default.removeItem(at: pkg.url)
            throw ImportError(folderName: sourceDir.lastPathComponent, underlying: error)
        }
    }

    /// Export the given site's source tree to a chosen folder, with an opt-in for `.git` history.
    static func exportSource(of site: SiteStore.Site) {
        let save = NSSavePanel()
        save.message = String(localized: "Export this site's source files to a folder.")
        save.nameFieldStringValue = site.name
        let gitToggle = NSButton(checkboxWithTitle: String(localized: "Include Git history (.git)"), target: nil, action: nil)
        gitToggle.state = .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        gitToggle.frame = NSRect(x: 12, y: 4, width: 256, height: 20)
        accessory.addSubview(gitToggle)
        save.accessoryView = accessory
        guard save.runModal() == .OK, let dest = save.url else { return }
        let includeGit = gitToggle.state == .on
        let pkgURL = site.packageURL
        // Off-load the copy from the main actor; surface any failure back on main via NSAlert.
        Task.detached {
            do {
                try PackageTransfer.exportSource(of: AnglesitePackage(url: pkgURL), to: dest, includeGit: includeGit)
            } catch {
                await MainActor.run { NSAlert(error: error).runModal() }
            }
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
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose an Anglesite site package.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            return try await registerPackage(at: url)
        } catch {
            throw ImportError(folderName: url.lastPathComponent, underlying: error)
        }
    }
}
