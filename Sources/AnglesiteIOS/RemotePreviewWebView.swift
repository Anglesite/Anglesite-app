#if os(iOS)
import SwiftUI
import WebKit
import AnglesiteBridge

/// iOS `WKWebView` preview shell for the remote-only runtime path (#71).
///
/// The caller owns the remote session and supplies the preview URL plus an optional
/// `AnglesiteScriptHandler`. This wrapper deliberately does not know about local files,
/// subprocesses, or container selection.
@MainActor
public struct RemotePreviewWebView: UIViewRepresentable {
    public typealias UIViewType = WKWebView

    private let url: URL
    private let scriptHandler: WKScriptMessageHandler?
    private let configureWebView: (WKWebView) -> Void

    public init(
        url: URL,
        scriptHandler: WKScriptMessageHandler? = nil,
        configureWebView: @escaping (WKWebView) -> Void = { _ in }
    ) {
        self.url = url
        self.scriptHandler = scriptHandler
        self.configureWebView = configureWebView
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WebViewBridge.localDevConfiguration(handler: scriptHandler)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        WebViewBridge.applyPreviewDefaults(to: webView)
        configureWebView(webView)
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    public func makeCoordinator() -> RemotePreviewWebViewCoordinator {
        RemotePreviewWebViewCoordinator()
    }
}
#endif
