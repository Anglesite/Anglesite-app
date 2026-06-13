import SwiftUI
import AppKit
import AnglesiteCore

/// The "Sites" launcher window: a list of known sites plus actions to open an
/// existing one or add a folder to the registry. This is the single entry point
/// to a site window now that there's no in-window sidebar.
///
/// Launch behavior: on the very first appearance of *this app session* the
/// launcher checks `AppSettings.lastOpenedSiteID`. If that site is still valid,
/// the launcher opens its window and dismisses itself — the user lands in the
/// site they were last working in. On subsequent appearances (the user re-opens
/// the launcher from the Window menu or the dock), no autoopen occurs.
struct SitesLauncherView: View {
    /// Tracks whether the autoopen attempt has already happened this app session.
    /// Static so re-instantiations of the view (e.g. after the user closes and
    /// reopens the launcher) don't retrigger the MRU path.
    private static var didAutoOpenAttempt = false

    @State private var sites: [SiteStore.Site] = []
    @State private var loadError: String?
    @State private var deciding = true
    @State private var showingNewSite = false
    /// The site awaiting a remove confirmation, or nil when no prompt is up. Drives the
    /// `.confirmationDialog`; cleared on confirm or cancel.
    @State private var siteToRemove: SiteStore.Site?
    @State private var wizardModel: NewSiteWizardModel?
    @State private var scaffolder: SiteScaffolder?
    @State private var sitesRootScopedURL: URL?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if deciding {
                // Render nothing while we decide whether to autoopen — avoids a
                // visible flash of the picker before we dismiss ourselves.
                Color(NSColor.windowBackgroundColor)
            } else {
                launcherUI
            }
        }
        .task { await onFirstAppear() }
        .navigationTitle("Sites")
    }

    private var launcherUI: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let loadError {
                errorState(loadError)
            } else if sites.isEmpty {
                emptyState
            } else {
                siteList
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 480)
        .sheet(isPresented: $showingNewSite) {
            if let wizardModel, let scaffolder {
                NewSiteWizard(
                    model: wizardModel,
                    scaffolder: scaffolder,
                    onComplete: { siteID in
                        showingNewSite = false
                        Task {
                            await refreshSites()
                            openWindow(value: siteID)
                            dismissWindow()
                        }
                    },
                    onCancel: { showingNewSite = false }
                )
                .onDisappear {
                    sitesRootScopedURL?.stopAccessingSecurityScopedResource()
                    sitesRootScopedURL = nil
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Sites").font(.title2.bold())
            Spacer()
            Button("Rescan sites", systemImage: "arrow.clockwise") {
                Task { await refreshSites() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Rescan ~/Sites")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var siteList: some View {
        List(sites) { site in
            Button {
                open(site: site)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: site.isValid
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(site.isValid ? Color.green : Color.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.name).font(.body.monospaced())
                        Text(site.path.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .disabled(!site.isValid)
            .accessibilityValue(site.isValid ? "Valid" : "Missing required files")
            .help(site.isValid
                  ? "Open \(site.name) in its own window"
                  : "Site is missing required files: \(site.missingSentinels.joined(separator: ", "))")
            .contextMenu {
                Button("Remove from Anglesite…", systemImage: "minus.circle", role: .destructive) {
                    siteToRemove = site
                }
            }
            .swipeActions(edge: .trailing) {
                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                    siteToRemove = site
                }
            }
        }
        .listStyle(.inset)
        .confirmationDialog(
            "Remove “\(siteToRemove?.name ?? "")” from Anglesite?",
            isPresented: Binding(
                get: { siteToRemove != nil },
                set: { if !$0 { siteToRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: siteToRemove
        ) { site in
            Button("Remove from Anglesite", role: .destructive) { removeSite(site) }
            Button("Cancel", role: .cancel) { siteToRemove = nil }
        } message: { site in
            // Removal only forgets the site here — the folder on disk is untouched, matching
            // `SiteStore.remove(id:)`. Owners can still open it in Finder, VS Code, or the CLI.
            Text("This removes it from Anglesite's list only. The files in \(site.path.path) are left on disk.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text("No Anglesite sites found")
                .font(.headline)
            Text("Create one with `/anglesite:start` in `~/Sites/<name>/`, or use **Add Site → Import existing site…** to add an existing project.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle).foregroundStyle(.orange)
            Text("Couldn't load sites").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Retry") { Task { await refreshSites() } }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Menu {
                Button("Create new site…") { Task { await presentNewSite() } }
                Button("Import existing site…") { openFolder() }
            } label: {
                Label("Add Site", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func open(site: SiteStore.Site) {
        openWindow(value: site.id)
        dismissWindow()
    }

    /// Forget `site` from the registry without touching its files. On MAS this also drops the
    /// site's persisted security-scoped bookmark, since that lives inline in the `Site` entry.
    /// We prune the local list directly rather than re-running `refreshSites()`: a DevID rescan
    /// of `~/Sites` would immediately rediscover a still-present in-root folder, undoing the
    /// removal visually. Persistence is handled by `remove(id:)`.
    private func removeSite(_ site: SiteStore.Site) {
        siteToRemove = nil
        Task {
            do {
                try await SiteStore.shared.remove(id: site.id)
                sites.removeAll { $0.id == site.id }
            } catch {
                loadError = "Couldn't remove \(site.name): \(error)"
            }
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an Anglesite project directory."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let site = try await SiteStore.shared.add(url)
                #if ANGLESITE_MAS
                // The panel grant is the only chance to mint a scoped bookmark — persist it now
                // so the grant survives relaunch. SiteWindow resolves it and holds access.
                let bookmark = try SecurityScopedBookmark.create(for: url)
                try await SiteStore.shared.setBookmark(bookmark, for: site.id)
                #endif
                await refreshSites()
                open(site: site)
            } catch {
                loadError = "Couldn't add \(url.lastPathComponent): \(error)"
            }
        }
    }

    @MainActor
    private func presentNewSite() async {
        let resolution = PluginRuntime.resolve()
        guard let pluginURL = resolution.url else {
            loadError = "Plugin not found — can't create a site. Reinstall the app."
            return
        }
        let catalog: ThemeCatalog
        do { catalog = try ThemeCatalog.load(pluginURL: pluginURL) }
        catch { loadError = "Couldn't load themes: \(error.localizedDescription)"; return }

        // Effective sites root (override or ~/Sites) — the same accessor SiteStore uses.
        let sitesRoot = AppSettings.shared.sitesRoot

        #if ANGLESITE_MAS
        guard let rootScope = await ensureSitesRootAccess(sitesRoot) else { return }  // user cancelled
        sitesRootScopedURL = rootScope
        #endif
        try? FileManager.default.createDirectory(at: sitesRoot, withIntermediateDirectories: true)

        let known = (try? await SiteStore.shared.refresh()) ?? []
        let takenSlugs = Set(known.map { SiteSlug.derive(from: $0.name) })

        let model = NewSiteWizardModel(catalog: catalog, slugTaken: { takenSlugs.contains($0) })

        scaffolder = SiteScaffolder(
            sitesRoot: sitesRoot,
            pluginURL: pluginURL,
            catalog: catalog,
            run: { exe, args, cwd in
                try await ProcessSupervisor.shared.run(executable: exe, arguments: args, currentDirectoryURL: cwd)
            },
            register: { url in
                let site = try await SiteStore.shared.add(url)
                #if ANGLESITE_MAS
                let bookmark = try SecurityScopedBookmark.create(for: url)
                try await SiteStore.shared.setBookmark(bookmark, for: site.id)
                #endif
                return site
            }
        )
        wizardModel = model
        showingNewSite = true
    }

    #if ANGLESITE_MAS
    /// Obtain (or reuse) a security-scoped grant to the sites root so the sandboxed build can
    /// create a new site folder under it. Returns the started-accessing URL, or nil if cancelled.
    @MainActor
    private func ensureSitesRootAccess(_ sitesRoot: URL) async -> URL? {
        if let data = AppSettings.shared.sitesRootBookmark,
           let resolved = try? SecurityScopedBookmark.resolve(data),
           resolved.url.startAccessingSecurityScopedResource() {
            if resolved.isStale, let fresh = try? SecurityScopedBookmark.create(for: resolved.url) {
                AppSettings.shared.sitesRootBookmark = fresh
            }
            return resolved.url
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = sitesRoot
        panel.prompt = "Grant Access"
        panel.message = "Choose your Sites folder so Anglesite can create the new site there."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if let data = try? SecurityScopedBookmark.create(for: url) {
            AppSettings.shared.sitesRootBookmark = data
        }
        return url.startAccessingSecurityScopedResource() ? url : nil
    }
    #endif

    // MARK: - Lifecycle

    private func onFirstAppear() async {
        await refreshSites()

        if !Self.didAutoOpenAttempt {
            Self.didAutoOpenAttempt = true
            if let id = AppSettings.shared.lastOpenedSiteID,
               sites.contains(where: { $0.id == id && $0.isValid }) {
                openWindow(value: id)
                dismissWindow()
                return
            }
        }
        deciding = false
    }

    private func refreshSites() async {
        do {
            try await SiteStore.shared.load()
            sites = try await SiteStore.shared.refresh()
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }
}
