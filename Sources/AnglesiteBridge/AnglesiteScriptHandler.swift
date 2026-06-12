import Foundation
import WebKit
import AnglesiteCore

/// `WKScriptMessageHandler` for the `anglesite` namespace. Two message types ride this bridge:
///
/// 1. `anglesite:apply-edit` (an `EditMessage`) — routed through the injected `EditRouter`,
///    reply delivered back to the WKWebView via `window.anglesite?._handleReply?.(<reply>)`.
/// 2. `anglesite:visible-elements` (a `VisibleElementReport`, #145/B.1) — dispatched to the
///    optional `onVisibleElements` callback. No reply; the JS side doesn't await one.
///
/// The interesting logic lives in `dispatch(body:via:onVisibleElements:)` — it's unit-tested
/// independent of `WKScriptMessage`, which has no public initializer and is awkward to fake.
///
/// **API change vs prior versions:** the static `handle(body:via:)` method is gone, replaced
/// by `dispatch(body:via:onVisibleElements:)`. All current callers are internal to this repo
/// (the `WKScriptMessageHandler` impl below, the unit tests, and `PreviewView`'s production
/// init); no deprecated shim is provided. If you're a downstream framework consumer hitting
/// this, the migration is mechanical: rename `handle` → `dispatch`, pass `nil` for
/// `onVisibleElements` to preserve the apply-edit-only behavior, and match on the richer
/// `DispatchResult` enum instead of `Result<EditReply, EditMessage.DecodeError>`.
public final class AnglesiteScriptHandler: NSObject, WKScriptMessageHandler {
    public typealias VisibleElementsHandler = @Sendable ([VisibleElement]) async -> Void

    private let router: EditRouter
    private let onVisibleElements: VisibleElementsHandler?
    private let logCenter: LogCenter

    public init(
        router: EditRouter,
        onVisibleElements: VisibleElementsHandler? = nil,
        logCenter: LogCenter = .shared
    ) {
        self.router = router
        self.onVisibleElements = onVisibleElements
        self.logCenter = logCenter
        super.init()
    }

    /// Outcome of dispatching one incoming message body. The script handler's
    /// `userContentController` reads this to decide whether to emit a reply or log a rejection.
    public enum DispatchResult: Sendable {
        /// `anglesite:apply-edit` succeeded; emit the reply back to the WKWebView.
        case editReply(EditReply)
        /// `anglesite:visible-elements` was forwarded to the optional handler.
        case visibleElementsHandled
        /// `anglesite:visible-elements` arrived but no `onVisibleElements` handler is installed.
        /// Useful for tests; in production the wiring is checked at handler-init time.
        case visibleElementsDropped
        /// Body was undecodable. Log and move on.
        case rejected(RejectionReason)

        public enum RejectionReason: Sendable, Equatable {
            case notAnObject
            case missingType
            case wrongType
            case unknownType(String)
            case editDecode(EditMessage.DecodeError)
            case visibleElementsDecode(VisibleElementReport.DecodeError)
        }
    }

    /// Peek at the `type` field, dispatch to the matching decoder, and route. Pure — no I/O
    /// beyond the router call and the visible-elements handler call.
    public static func dispatch(
        body: Any,
        via router: EditRouter,
        onVisibleElements: VisibleElementsHandler? = nil
    ) async -> DispatchResult {
        guard let dict = body as? [String: Any] else { return .rejected(.notAnObject) }
        guard let rawType = dict["type"] else { return .rejected(.missingType) }
        guard let typeStr = rawType as? String else { return .rejected(.wrongType) }

        switch typeStr {
        case EditMessage.MessageType.applyEdit.rawValue:
            switch EditMessage.decode(from: body) {
            case .success(let message):
                let reply = await router.apply(message)
                return .editReply(reply)
            case .failure(let error):
                return .rejected(.editDecode(error))
            }

        case VisibleElementReport.messageType:
            switch VisibleElementReport.decode(from: body) {
            case .success(let report):
                guard let handler = onVisibleElements else { return .visibleElementsDropped }
                await handler(report.elements)
                return .visibleElementsHandled
            case .failure(let error):
                return .rejected(.visibleElementsDecode(error))
            }

        default:
            return .rejected(.unknownType(typeStr))
        }
    }

    /// Deprecated forwarder for the old `handle(body:via:)` signature so out-of-tree adopters
    /// get a fix-it instead of a cryptic missing-member error. Always passes `nil` for
    /// `onVisibleElements`, matching the prior behavior (apply-edit only). Returns the same
    /// `Result<EditReply, EditMessage.DecodeError>` shape callers were already matching on —
    /// rejection reasons map back into the legacy decode-error type.
    @available(*, deprecated, renamed: "dispatch(body:via:onVisibleElements:)",
               message: "handle() is apply-edit only and returns a less expressive shape. Use dispatch(body:via:onVisibleElements:) — it covers visible-elements routing too and exposes the richer DispatchResult.")
    public static func handle(body: Any, via router: EditRouter) async -> Result<EditReply, EditMessage.DecodeError> {
        switch await dispatch(body: body, via: router, onVisibleElements: nil) {
        case .editReply(let reply):
            return .success(reply)
        case .rejected(.editDecode(let error)):
            return .failure(error)
        case .rejected(.notAnObject):
            return .failure(.notAnObject)
        case .rejected(.missingType):
            return .failure(.missingField("type"))
        case .rejected(.wrongType):
            return .failure(.wrongType(field: "type", expected: "string"))
        case .rejected(.unknownType(let s)):
            return .failure(.unknownType(s))
        case .rejected(.visibleElementsDecode):
            // Unreachable under `handle`'s contract (apply-edit only). Bubble up as
            // unknown-type rather than crash; deprecated path, callers should migrate.
            return .failure(.unknownType(VisibleElementReport.messageType))
        case .visibleElementsHandled, .visibleElementsDropped:
            // Unreachable: handler is nil. Same fallthrough as above.
            return .failure(.unknownType(VisibleElementReport.messageType))
        }
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebViewBridge.scriptMessageNamespace else { return }
        let body = message.body
        let webView = message.webView
        let router = self.router
        let onVisibleElements = self.onVisibleElements
        let logCenter = self.logCenter
        Task {
            switch await Self.dispatch(body: body, via: router, onVisibleElements: onVisibleElements) {
            case .editReply(let reply):
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
            case .visibleElementsHandled:
                return
            case .visibleElementsDropped:
                // A visible-elements message arrived but no `onVisibleElements` handler is
                // installed. Production wiring (PreviewView with an annotationProvider)
                // always installs one; reaching here implies a regression. Log so the wiring
                // failure is observable rather than silently swallowing all Siri reports.
                await logCenter.append(
                    source: "bridge",
                    stream: .stderr,
                    text: "visible-elements message dropped: no handler installed (provider not threaded through PreviewView?)"
                )
            case .rejected(let reason):
                await logCenter.append(
                    source: "bridge",
                    stream: .stderr,
                    text: "rejected message: \(reason)"
                )
            }
        }
    }
}
