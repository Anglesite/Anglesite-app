import SwiftUI
import WebKit
import AnglesiteBridge

/// SwiftUI wrapper around a `WKWebView` showing the live Astro dev server.
///
/// `url` is owned by the caller (a `PreviewModel` driven by `PreviewSession`). When it changes —
/// e.g. a supervised dev-server restart rebinds a new port — the web view reloads from the new URL.
struct PreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        // Each webview gets its own script-message handler so the WKWebView retains the router for
        // its lifetime; `LoggingEditRouter` is the placeholder until Phase 5 lands a real one.
        let handler = AnglesiteScriptHandler(router: LoggingEditRouter())
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
