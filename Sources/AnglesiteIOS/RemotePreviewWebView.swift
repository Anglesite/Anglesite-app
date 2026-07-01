#if os(iOS)
import SwiftUI
import WebKit

/// iOS `WKWebView` preview shell for the remote-only runtime path (#71).
///
/// The caller owns the remote session and supplies the preview URL plus an optional
/// script handler. This wrapper deliberately does not know about local files, subprocesses,
/// local containers, or the macOS `AnglesiteCore` runtime graph.
@MainActor
public struct RemotePreviewWebView: UIViewRepresentable {
    public typealias UIViewType = WKWebView

    public static let defaultScriptMessageNamespace = "anglesite"

    private let url: URL
    private let scriptHandler: WKScriptMessageHandler?
    private let scriptMessageNamespace: String
    private let configureWebView: (WKWebView) -> Void

    public init(
        url: URL,
        scriptHandler: WKScriptMessageHandler? = nil,
        scriptMessageNamespace: String = Self.defaultScriptMessageNamespace,
        configureWebView: @escaping (WKWebView) -> Void = { _ in }
    ) {
        self.url = url
        self.scriptHandler = scriptHandler
        self.scriptMessageNamespace = scriptMessageNamespace
        self.configureWebView = configureWebView
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let scriptHandler {
            configuration.userContentController.add(scriptHandler, name: scriptMessageNamespace)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
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
