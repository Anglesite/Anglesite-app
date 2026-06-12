import SwiftUI
import AppKit
import WebKit
import AppIntents
import AnglesiteBridge
import AnglesiteCore
import AnglesiteIntents

/// SwiftUI wrapper around a `WKWebView` showing the live Astro dev server.
///
/// `url` is owned by the caller (a `PreviewModel` driven by a `SiteRuntime`). When it changes —
/// e.g. a supervised dev-server restart rebinds a new port — the web view reloads from the new URL.
///
/// `router` is the `EditRouter` the in-page overlay's `AnglesiteScriptHandler` forwards edits to.
/// In production it's the `MCPApplyEditRouter` from `PreviewModel`, wrapping the session's
/// `MCPClient`; tests can substitute any `EditRouter`.
///
/// `annotationProvider` is the per-window `PreviewAnnotationProvider` (Siri AI Phase B). When
/// supplied, the script handler routes `anglesite:visible-elements` messages into it, and the
/// WKWebView gets an `appEntityUIElementProvider` so AppKit's hit-test resolves visible regions
/// to live entities. Nil → those features are inert (overlay still works for hover/click/drop).
struct PreviewView: NSViewRepresentable {
    let url: URL
    let router: EditRouter
    let annotationProvider: PreviewAnnotationProvider?

    func makeNSView(context: Context) -> WKWebView {
        let onVisibleElements: AnglesiteScriptHandler.VisibleElementsHandler? = annotationProvider.map { provider in
            // `provider` is `@MainActor`, so the implicit hop happens at the `update(_:)` call.
            // Captured strongly: the handler is owned by the WKWebView, which is owned by
            // SwiftUI's NSViewRepresentable lifecycle; the provider is owned by SiteWindow's
            // `@State`, which outlives the WKWebView. The closure becomes unreachable when the
            // WKWebView is torn down, releasing the strong reference.
            { @Sendable elements in await provider.update(elements) }
        }
        let handler = AnglesiteScriptHandler(router: router, onVisibleElements: onVisibleElements)
        let webView = WKWebView(frame: .zero, configuration: WebViewBridge.localDevConfiguration(handler: handler))
        WebViewBridge.applyLocalDevDefaults(to: webView)
        if let annotationProvider {
            webView.appEntityUIElementProvider = { [weak annotationProvider] _, hitContext in
                guard let annotationProvider else { return [] }
                return annotationProvider.uiElements(for: hitContext)
            }
        }
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
