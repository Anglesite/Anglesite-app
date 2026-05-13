import Foundation
import WebKit
import AnglesiteCore

/// `WKScriptMessageHandler` for the `anglesite` namespace. Decodes each incoming `EditMessage`,
/// routes it through the injected `EditRouter`, and posts the `EditReply` back to the originating
/// WKWebView via `evaluateJavaScript("window.anglesite?._handleReply?.(<reply>)")`.
///
/// The interesting logic lives in the pure `handle(body:via:)` static function — it's unit-tested
/// independent of `WKScriptMessage`, which has no public initializer and is awkward to fake.
public final class AnglesiteScriptHandler: NSObject, WKScriptMessageHandler {
    private let router: EditRouter
    private let logCenter: LogCenter

    public init(router: EditRouter, logCenter: LogCenter = .shared) {
        self.router = router
        self.logCenter = logCenter
        super.init()
    }

    /// Pure decode → route → reply. Returns `.failure` for undecodable input (no reply: the JS
    /// side never sent a correlation `id` we can trust, so callers should just log it). Returns
    /// `.success(reply)` once the router has produced one.
    public static func handle(body: Any, via router: EditRouter) async -> Result<EditReply, EditMessage.DecodeError> {
        switch EditMessage.decode(from: body) {
        case .failure(let error):
            return .failure(error)
        case .success(let message):
            let reply = await router.apply(message)
            return .success(reply)
        }
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebViewBridge.scriptMessageNamespace else { return }
        let body = message.body
        let webView = message.webView
        let router = self.router
        let logCenter = self.logCenter
        Task {
            switch await Self.handle(body: body, via: router) {
            case .failure(let error):
                await logCenter.append(
                    source: "bridge",
                    stream: .stderr,
                    text: "rejected edit message: \(error)"
                )
            case .success(let reply):
                guard let webView else { return }
                guard let data = try? JSONEncoder().encode(reply),
                      let json = String(data: data, encoding: .utf8)
                else {
                    await logCenter.append(source: "bridge", stream: .stderr, text: "failed to encode reply for id=\(reply.id)")
                    return
                }
                let script = "window.anglesite?._handleReply?.(\(json))"
                await MainActor.run {
                    webView.evaluateJavaScript(script)
                }
            }
        }
    }
}
