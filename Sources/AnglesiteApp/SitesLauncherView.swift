import SwiftUI
import AppKit
import AnglesiteCore
import AnglesiteIntents

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
    /// Guards `presentNewSite()` against a double-trigger while it is preparing (it `await`s
    /// before `newSiteSession` is set, so two near-simultaneous callers could both pass a
    /// `newSiteSession == nil` check). Reset via `defer` on every exit path.
    @State private var preparingNewSite = false
    /// The site awaiting a remove confirmation, or nil when no prompt is up. Drives the
    /// `.confirmationDialog`; SwiftUI clears it (via the `isPresented` binding) when any dialog
    /// button is tapped.
    @State private var siteToRemove: SiteStore.Site?
    /// The name shown in the confirmation title. Held separately from `siteToRemove` so the title
    /// stays stable through the dismiss animation — reading `siteToRemove?.name` directly would
    /// collapse to "" the instant the dialog clears the optional.
    @State private var siteToRemoveName = ""
    private struct NewSiteSession: Identifiable {
        let id = UUID()
        let model: NewSiteWizardModel
        let scaffolder: SiteScaffolder
    }
    /// Non-nil while the New Site wizard is showing; nil dismisses it.
    @State private var newSiteSession: NewSiteSession?
    @State private var sitesRootScopedURL: URL?
    @State private var router = WindowRouter.shared

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
        .onChange(of: router.newSiteRequested) { _, requested in
            guard requested else { return }
            router.newSiteRequested = false
            Task { await presentNewSite() }
        }
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
        .sheet(item: $newSiteSession) { session in
            NewSiteWizard(
                model: session.model,
                scaffolder: session.scaffolder,
                onComplete: { siteID in
                    newSiteSession = nil
                    Task {
                        await refreshSites()
                        openWindow(value: siteID)
                        dismissWindow()
                    }
                },
                onCancel: { newSiteSession = nil }
            )
            .onDisappear {
                sitesRootScopedURL?.stopAccessingSecurityScopedResource()
                sitesRootScopedURL = nil
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
                    promptRemove(site)
                }
            }
            .swipeActions(edge: .trailing) {
                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                    promptRemove(site)
                }
            }
        }
        .listStyle(.inset)
        .confirmationDialog(
            "Remove “\(siteToRemoveName)” from Anglesite?",
            isPresented: Binding(
                get: { siteToRemove != nil },
                set: { if !$0 { siteToRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: siteToRemove
        ) { site in
            Button("Remove from Anglesite", role: .destructive) { removeSite(site) }
            Button("Cancel", role: .cancel) {}
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

    /// Raise the remove-confirmation dialog for `site`. `siteToRemoveName` is captured here so the
    /// dialog title survives the dismiss animation (see the property's note).
    private func promptRemove(_ site: SiteStore.Site) {
        siteToRemoveName = site.name
        siteToRemove = site
    }

    /// Forget `site` from the registry without touching its files. On MAS this also drops the
    /// site's persisted security-scoped bookmark, since that lives inline in the `Site` entry.
    /// We prune the local list directly rather than re-running `refreshSites()`: a DevID rescan
    /// of `~/Sites` would immediately rediscover a still-present in-root folder, undoing the
    /// removal visually. Persistence is handled by `remove(id:)`.
    ///
    /// An already-open `SiteWindow` for this site auto-closes: it observes `SiteStore.changeStream()`
    /// and dismisses itself when its id leaves the registry, which tears down its dev-server/MCP
    /// subprocess via `onDisappear` (#188).
    private func removeSite(_ site: SiteStore.Site) {
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
        Task {
            do {
                guard let site = try await SiteActions.pickAndRegisterSite() else { return }
                await refreshSites()
                open(site: site)
            } catch {
                loadError = "Couldn't add the chosen folder: \(error)"
            }
        }
    }

    @MainActor
    private func presentNewSite() async {
        guard newSiteSession == nil, !preparingNewSite else { return }
        preparingNewSite = true
        defer { preparingNewSite = false }
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

        let scaffolder = SiteScaffolder(
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
        newSiteSession = NewSiteSession(model: model, scaffolder: scaffolder)
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

        // A File ▸ New Site that opened this launcher set the flag before our `.task` ran;
        // `.onChange` won't fire for that initial value, so consume it here.
        if router.newSiteRequested {
            router.newSiteRequested = false
            deciding = false
            await presentNewSite()
            return
        }

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
