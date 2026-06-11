import SwiftUI
import AppKit
import AnglesiteCore
import AnglesiteBridge
import AnglesiteIntents

/// Owns process-level lifecycle that SwiftUI's `App` value type can't: prime the npm cache on
/// launch, and drain every supervised child on quit so nothing outlives the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register App Intents dependencies before the app surface comes up so backgrounded
        // intent processes (and #101's system MCP entry, later) can resolve immediately.
        // `bootstrap()` is async (it awaits the Spotlight handler installation on `SiteStore`);
        // we kick it off here without waiting — the launcher view's `task` modifier doesn't
        // block on it, and bootstrap's own defensive `load()` closes any race.
        Task { await AnglesiteIntents.bootstrap() }

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
struct AnglesiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
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

    var body: some Scene {
        // The launcher is the first scene so it's the default window at launch (used when
        // SwiftUI has nothing to restore). It autoopens the most-recently-used site from its
        // own .task — see SitesLauncherView.onFirstAppear().
        Window("Sites", id: "sites") {
            SitesWindowRoot(openWindow: openWindow)
        }
        .windowResizability(.contentSize)
        .commands {
            // "Check for Updates…" lives in the standard slot Mac users expect — directly
            // under "About Anglesite" in the application menu. `CommandGroup(after: .appInfo)`
            // puts it there.
            #if !ANGLESITE_MAS
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            #endif
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
            SiteWindow(siteID: siteID)
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
