import SwiftUI
import AppKit
import AnglesiteCore
import AnglesiteBridge

/// Owns process-level lifecycle that SwiftUI's `App` value type can't: prime the npm cache on
/// launch, and on quit drain every supervised child (Astro dev server, MCP server, ad-hoc Node)
/// so nothing outlives the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
    /// Sparkle updater, held for the app's lifetime so its automatic-check timer keeps firing.
    @StateObject private var updater = Updater()

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
        WindowGroup("Anglesite") {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // "Check for Updates…" lives in the standard slot Mac users expect — directly
            // under "About Anglesite" in the application menu. `CommandGroup(after: .appInfo)`
            // puts it there.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
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
