import SwiftUI
import WebKit
import AnglesiteBridge

/// SwiftUI wrapper around a `WKWebView` showing the live Astro dev server.
///
/// `url` is owned by the caller (a `PreviewModel` driven by a `SiteRuntime`). When it changes —
/// e.g. a supervised dev-server restart rebinds a new port — the web view reloads from the new URL.
///
/// `router` is the `EditRouter` the in-page overlay's `AnglesiteScriptHandler` forwards edits to.
/// In production it's the `MCPApplyEditRouter` from `PreviewModel`, wrapping the session's
/// `MCPClient`; tests can substitute any `EditRouter`.
struct PreviewView: NSViewRepresentable {
    let url: URL
    let router: EditRouter

    func makeNSView(context: Context) -> WKWebView {
        // Each webview gets its own script-message handler so the WKWebView retains the router for
        // its lifetime. The router itself is shared (closure-captured by PreviewModel).
        let handler = AnglesiteScriptHandler(router: router)
        let webView = WKWebView(frame: .zero, configuration: WebViewBridge.localDevConfiguration(handler: handler))
        WebViewBridge.applyLocalDevDefaults(to: webView)
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedURL: URL?
    }
}
