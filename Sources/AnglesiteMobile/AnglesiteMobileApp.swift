import SwiftUI

/// iOS thin client (#71): a remote-only shell over `RemoteSandboxSiteRuntime`. No local files,
/// no subprocesses, no local containers — the site runs in the user's Cloudflare sandbox and
/// this app is a `WKWebView` plus MCP-over-HTTPS edits (design 2026-06-23).
@main
struct AnglesiteMobileApp: App {
    @State private var model = RemoteSessionModel()

    var body: some Scene {
        WindowGroup {
            RemoteSessionScreen(model: model)
        }
    }
}
