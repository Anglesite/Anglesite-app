import SwiftUI
import AnglesiteCore
import AnglesiteBridge

@main
struct AnglesiteApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Anglesite") {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // Debug pane lives off the View menu — `⌥⌘D` keeps it discoverable without
            // crowding the primary commands. Phase 3 surfaces every subprocess line here.
            CommandGroup(after: .toolbar) {
                Button("Show Debug Pane") {
                    openWindow(id: "debug")
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
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
