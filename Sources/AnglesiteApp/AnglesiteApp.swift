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
    /// Project-local retrieval index used by assistant tools for file-cited RAG context (#307).
    let knowledgeIndex = SiteKnowledgeIndex()
    /// On-device semantic ranker layered over `knowledgeIndex`, synced by the preview runtime so
    /// assistant retrieval ranks by meaning, not just keywords (#312). `nil` when no on-device
    /// embedding model is available — the whole chain takes `SemanticRanker?`, so retrieval then
    /// degrades to pure lexical (never the test-double fake, which would blend nonsense vectors).
    ///
    /// Populated asynchronously from `applicationDidFinishLaunching` because building the
    /// `NLContextualEmbedding` provider calls `model.load()` (hundreds of ms of asset/model init),
    /// which must not run on the main thread during launch. A site window opened in the brief
    /// pre-load window captures `nil` and stays lexical-only for that session (reopening picks up
    /// the ranker) — an acceptable degradation since the launcher is shown first.
    ///
    /// In-memory for v0: the per-site `Config/` embedding cache (`SemanticIndexCache`) and
    /// incremental `upsert`/`remove` re-embedding are built + tested but deliberately not wired
    /// yet — the shared app-global index architecture needs per-site cache routing the runtime
    /// can derive, which is a follow-up.
    var semanticRanker: SemanticRanker?

    /// On-device embedding provider, best-first: the multilingual transformer
    /// (`NLContextualEmbedding`), then the lighter `NLEmbedding.sentenceEmbedding`, then `nil`
    /// (→ pure-lexical retrieval). Never the test-double fake. Runs the model load, so call it off
    /// the main thread.
    private static func makeEmbeddingProvider() -> (any EmbeddingProvider)? {
        if let contextual = NLContextualEmbeddingProvider() { return contextual }
        if let sentence = NLEmbeddingProvider() { return sentence }
        return nil
    }
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

        // Build the on-device embedding provider off the main thread (model load is expensive),
        // then publish the ranker on the main actor for new site windows to capture.
        Task { [weak self] in
            let provider = await Task.detached(priority: .utility) { Self.makeEmbeddingProvider() }.value
            await MainActor.run { self?.semanticRanker = provider.map { SemanticRanker(provider: $0, cache: nil) } }
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

    private func showAboutPanel() {
        // Credits carries the build info the standard fields don't: the dev phase and the
        // host OS. App name and version come from the bundle via .applicationName and the
        // default .applicationVersion (CFBundleShortVersionString) — passing "Phase X" there
        // would clobber the real version and render as "Version Phase X".
        let credits = NSAttributedString(
            string: "Phase \(BuildInfo.phase) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: BuildInfo.appName,
            .credits: credits
        ])
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
            CommandGroup(replacing: .appInfo) {
                Button("About Anglesite") { showAboutPanel() }
            }

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
            // Export is its own Commands type so @FocusedValue tracks scene focus (see ExportSiteCommands).
            ExportSiteCommands()
            // "Show Web Inspector" in the View menu — its own Commands type for the same focus reason.
            WebInspectorCommands()
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
            SiteWindow(
                siteID: siteID,
                contentGraph: appDelegate.contentGraph,
                knowledgeIndex: appDelegate.knowledgeIndex,
                semanticRanker: appDelegate.semanticRanker,
                contentIndexerStore: appDelegate.contentIndexerStore
            )
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
