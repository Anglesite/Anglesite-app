import SwiftUI
import AppKit
import AnglesiteCore
import AnglesiteBridge
import AnglesiteIntents

/// Owns process-level lifecycle that SwiftUI's `App` value type can't: prime the npm cache on
/// launch, and drain every supervised child on quit so nothing outlives the app.
/// Holds the app-lifetime `ContentSpotlightIndexer` once `bootstrap` finishes populating it.
/// `@Observable` so a `SiteWindow` constructed *before* bootstrap completes still reacts when the
/// indexer arrives (enabling its Siri AI Readiness button) — passing the bare optional through the
/// `WindowGroup` constructor would freeze whatever value existed at body-eval time.
@MainActor
@Observable
final class ContentIndexerStore {
    var indexer: ContentSpotlightIndexer?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Single shared `SiteContentGraph` for the app's lifetime. Passed into
    /// `AnglesiteIntents.bootstrap` so it can be registered with `AppDependencyManager`;
    /// will also be threaded into `LocalSiteRuntime` in A.8 (#142).
    let contentGraph = SiteContentGraph()
    let contentIndexerStore = ContentIndexerStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register App Intents dependencies before the app surface comes up so backgrounded
        // intent processes (and #101's system MCP entry, later) can resolve immediately.
        // `bootstrap()` is async (it awaits the Spotlight handler installation on `SiteStore`);
        // we kick it off here without waiting — the launcher view's `task` modifier doesn't
        // block on it, and bootstrap's own defensive `load()` closes any race.
        Task { [contentGraph, contentIndexerStore] in
            // This Task inherits the @MainActor context, so the store write needs no extra hop.
            contentIndexerStore.indexer = await AnglesiteIntents.bootstrap(contentGraph: contentGraph)
        }

        // Begin mirroring the site registry so the File ▸ Open Recent submenu is populated
        // and stays current. Idempotent; safe on the main actor.
        Task { @MainActor in RecentSitesModel.shared.start() }

        // Extract the bundled npm cache into Application Support so the first site `npm install`
        // is offline-fast. No-op when nothing's bundled or it's already current; logged either way.
        Task {
            do {
                let outcome = try await NodeModulesCache.shared.prime()
                await LogCenter.shared.append(source: "npm-cache", stream: .stdout, text: "prime: \(outcome)")
            } catch {
                await LogCenter.shared.append(source: "npm-cache", stream: .stderr, text: "prime failed: \(error)")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await ProcessSupervisor.shared.shutdownAll(timeout: 5)
            await MainActor.run { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

@main
@MainActor
struct AnglesiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    /// Live mirror of the site registry for the File ▸ Open Recent submenu. Held as `@State`
    /// so SwiftUI re-evaluates `.commands` when its `sites` change. Started in AppDelegate.
    @State private var recent = RecentSitesModel.shared
    /// Tracks the site id of the currently key site window. SwiftUI's `@FocusedValue` updates
    /// automatically as windows gain and lose key status — no manual set/clear needed.
    @FocusedValue(\.siteID) private var focusedSiteID
    #if !ANGLESITE_MAS
    /// Sparkle updater, held for the app's lifetime so its automatic-check timer keeps firing.
    /// MAS builds update through the App Store and have no Sparkle dependency (Phase 10.1).
    @StateObject private var updater = Updater()
    #endif

    /// Computed once at launch: Debug builds always show the Debug-pane menu item; Release builds
    /// only when the user opted in (Settings) or held ⌥ while launching. A settings change takes
    /// effect on the next launch — the menu bar is built once here.
    private let debugPaneMenuVisible: Bool

    init() {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        debugPaneMenuVisible = DebugPaneVisibility.menuItemVisible(
            isDebugBuild: isDebugBuild,
            settingEnabled: AppSettings.shared.debugPaneEnabled,
            optionHeldAtLaunch: NSEvent.modifierFlags.contains(.option)
        )
    }

    /// File ▸ Open Site… — window-independent, so it runs from any focused window.
    @MainActor
    private func openSiteFromMenu() async {
        do {
            guard let site = try await SiteActions.pickAndRegisterSite() else { return }
            openWindow(value: site.id)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open that site"
            // `SiteActions.ImportError.localizedDescription` names the package and the reason;
            // other errors fall back to their OS-provided message rather than a raw enum dump.
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    var body: some Scene {
        // The launcher is the first scene so it's the default window at launch (used when
        // SwiftUI has nothing to restore). It autoopens the most-recently-used site from its
        // own .task — see SitesLauncherView.onFirstAppear().
        Window("Sites", id: "sites") {
            SitesWindowRoot(openWindow: openWindow)
                .onOpenURL { url in
                    // Guard on the extension only (zero I/O on the main thread); `record` reads and
                    // validates the marker and throws a legible error if it isn't a real package.
                    guard url.pathExtension == AnglesitePackage.packageExtension else { return }
                    Task { @MainActor in
                        do {
                            let site = try await SiteStore.shared.record(AnglesitePackage(url: url))
                            #if ANGLESITE_MAS
                            // Mint from the canonicalized recorded path; let a failure surface to the
                            // catch (logged) rather than silently leaving the site grantless.
                            let bm = try SecurityScopedBookmark.create(for: site.packageURL)
                            try await SiteStore.shared.setBookmark(bm, for: site.id)
                            #endif
                            openWindow(value: site.id)
                        } catch {
                            await LogCenter.shared.append(source: "open-url", stream: .stderr, text: "open \(url.lastPathComponent) failed: \(error.localizedDescription)")
                        }
                    }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Site") {
                    // Ensure the launcher exists to host the wizard sheet, then ask it to open.
                    openWindow(id: "sites")
                    WindowRouter.shared.requestNewSite()
                }
                .keyboardShortcut("n")

                Button("Open Site…") {
                    Task { await openSiteFromMenu() }
                }
                .keyboardShortcut("o")

                Menu("Open Recent") {
                    ForEach(recent.sites) { site in
                        Button(site.name) { openWindow(value: site.id) }
                            .disabled(!site.isValid)
                    }
                    if recent.sites.isEmpty {
                        Button("No Recent Sites") {}.disabled(true)
                    }
                }
                Divider()
                Button("Import Site…") {
                    Task { @MainActor in
                        do {
                            if let site = try await SiteActions.importPackage() {
                                openWindow(value: site.id)
                            }
                        } catch {
                            NSAlert(error: error).runModal()
                        }
                    }
                }
            }
            // "Check for Updates…" lives in the standard slot Mac users expect — directly
            // under "About Anglesite" in the application menu. `CommandGroup(after: .appInfo)`
            // puts it there.
            #if !ANGLESITE_MAS
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            #endif
            // Export lives after the standard Save items. Enabled only when a site window is focused.
            CommandGroup(after: .importExport) {
                Button("Export Site Source…") {
                    Task { @MainActor in
                        if let id = focusedSiteID,
                           let site = await SiteStore.shared.find(id: id) {
                            SiteActions.exportSource(of: site, includeGit: false)
                        }
                    }
                }
                .disabled(focusedSiteID == nil)
            }
            // Debug pane lives off the View menu — `⌥⌘D` keeps it discoverable without crowding
            // the primary commands. Hidden in Release unless explicitly enabled (see init()).
            CommandGroup(after: .toolbar) {
                if debugPaneMenuVisible {
                    Button("Show Debug Pane") {
                        openWindow(id: "debug")
                    }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                }
            }
        }

        // Per-site windows, keyed by SiteStore.Site.id (a stable path-derived String).
        // Each window owns its own PreviewModel/DeployModel/ChatModel and dev-server lifetime.
        // SwiftUI dedupes openWindow(value:) calls, so opening the same site twice just
        // focuses the existing window.
        WindowGroup(for: String.self) { $siteID in
            // SiteWindow takes the optional directly so it can dismiss itself and
            // route to the launcher when restoration hands us a nil or unresolvable
            // id. If we short-circuit with `if let siteID` here the SiteWindow never
            // instantiates and an empty restored window strands the user.
            SiteWindow(siteID: siteID, contentGraph: appDelegate.contentGraph, contentIndexerStore: appDelegate.contentIndexerStore)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Window("Anglesite Debug", id: "debug") {
            DebugPaneView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.bottomTrailing)
        .defaultSize(width: 900, height: 500)

        Settings {
            SettingsView()
        }
    }
}
