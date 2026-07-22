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
    private let makeConfiguration: (() -> WKWebViewConfiguration)?
    private let prepareBeforeLoad: ((WKWebView) async -> Void)?
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
        self.makeConfiguration = nil
        self.prepareBeforeLoad = nil
        self.configureWebView = configureWebView
    }

    /// Caller-owned configuration variant: the session shell builds the full
    /// `WKWebViewConfiguration` itself (script handler, overlay user script) and can await
    /// `prepareBeforeLoad` — e.g. injecting the session-token cookie so the auth-proxy sees it
    /// on the very first request — before the preview URL is loaded.
    public init(
        url: URL,
        makeConfiguration: @escaping () -> WKWebViewConfiguration,
        prepareBeforeLoad: ((WKWebView) async -> Void)? = nil,
        configureWebView: @escaping (WKWebView) -> Void = { _ in }
    ) {
        self.url = url
        self.scriptHandler = nil
        self.scriptMessageNamespace = Self.defaultScriptMessageNamespace
        self.makeConfiguration = makeConfiguration
        self.prepareBeforeLoad = prepareBeforeLoad
        self.configureWebView = configureWebView
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration: WKWebViewConfiguration
        if let makeConfiguration {
            configuration = makeConfiguration()
        } else {
            configuration = WKWebViewConfiguration()
            if let scriptHandler {
                configuration.userContentController.add(scriptHandler, name: scriptMessageNamespace)
            }
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        configureWebView(webView)
        context.coordinator.loadedURL = url
        if let prepareBeforeLoad {
            // Await the pre-load work (async cookie-store writes) before the first request;
            // `WKWebView` tolerates `load` arriving a beat after creation.
            let target = url
            Task { @MainActor in
                await prepareBeforeLoad(webView)
                webView.load(URLRequest(url: target))
            }
        } else {
            webView.load(URLRequest(url: url))
        }
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
