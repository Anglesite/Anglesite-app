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
    }

    private var header: some View {
        HStack {
            Text("Sites").font(.title2.bold())
            Spacer()
            Button {
                Task { await refreshSites() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
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
            .help(site.isValid
                  ? "Open \(site.name) in its own window"
                  : "Site is missing required files: \(site.missingSentinels.joined(separator: ", "))")
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text("No Anglesite sites found")
                .font(.headline)
            Text("Create one with `/anglesite:start` in `~/Sites/<name>/`, or use **Open Folder…** below to add an existing project.")
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
            Button("Open Folder…") { openFolder() }
            Spacer()
            Text("New Site…")
                .foregroundStyle(.tertiary)
                .help("Coming soon — for now, run /anglesite:start from Claude Code in ~/Sites/")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func open(site: SiteStore.Site) {
        openWindow(value: site.id)
        dismissWindow()
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
                await refreshSites()
                open(site: site)
            } catch {
                loadError = "Couldn't add \(url.lastPathComponent): \(error)"
            }
        }
    }

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
