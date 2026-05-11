import SwiftUI
import AnglesiteCore
import AnglesiteBridge

@main
struct AnglesiteApp: App {
    var body: some Scene {
        WindowGroup("Anglesite") {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }
    }
}
