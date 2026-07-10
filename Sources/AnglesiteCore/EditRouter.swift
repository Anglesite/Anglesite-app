import Foundation

/// What the bridge says back to the overlay after handling an `EditMessage`. The struct is
/// `Encodable` because it gets `JSONEncoder()`'d straight into a `evaluateJavaScript` call —
/// `window.anglesite?._handleReply?.(<this object>)` — for the JS side to correlate via `id`.
public struct EditReply: Sendable, Equatable, Encodable {
    public let id: String
    public let status: Status
    /// Human-readable detail. Always present for `.failed` / `.ambiguous`; optional for `.applied`.
    public let message: String?
    /// Source file the patch landed on (relative path within the site). Present on `.applied`
    /// when the plugin's structured reply included it; `nil` for `.failed` / `.ambiguous` and
    /// for replies the router couldn't parse as JSON.
    public let file: String?
    /// SHA of the commit on `refs/heads/anglesite/edits` that captures this edit. `nil` when
    /// the site isn't a git repo, or for non-`.applied` replies.
    public let commit: String?
    /// Op-scoped metadata. For `replace-image-src` carries `{ src, srcset? }`. `nil` for ops
    /// that don't surface overlay-side metadata.
    public let result: ImageResult?
    /// Preview-only: the source fragment before/after the would-be change (`.preview` status).
    public let before: String?
    public let after: String?
    /// The op the preview/apply was for (e.g. "edit-style"). `nil` outside preview.
    public let op: String?
    /// Piggybacked component model — present when the plugin's structured `.applied` reply
    /// included a `model` key (Component Editor CSS write ops), sparing the app a second
    /// `get_component_model` round-trip after the edit. `nil` otherwise.
    public let model: ComponentModel?
    /// Machine-readable refusal code from the plugin's `anglesite:edit-failed` body (e.g.
    /// `"stale"`, `"no-match"`, `"invalid-input"`) — present whenever the router could parse a
    /// structured failure. Callers that need to distinguish failure kinds (e.g. staleness vs. a
    /// routine refusal) should switch on this instead of substring-matching `message`, which is
    /// free-form prose the plugin is free to reword.
    public let reason: String?

    public struct ImageResult: Sendable, Equatable, Encodable {
        public let src: String
        public let srcset: String?

        public init(src: String, srcset: String?) {
            self.src = src
            self.srcset = srcset
        }
    }

    public enum Status: String, Sendable, Equatable, Encodable {
        case applied, failed, ambiguous, preview
    }

    public init(
        id: String,
        status: Status,
        message: String?,
        file: String? = nil,
        commit: String? = nil,
        result: ImageResult? = nil,
        before: String? = nil,
        after: String? = nil,
        op: String? = nil,
        model: ComponentModel? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.status = status
        self.message = message
        self.file = file
        self.commit = commit
        self.result = result
        self.before = before
        self.after = after
        self.op = op
        self.model = model
        self.reason = reason
    }
}

/// The seam between the JS bridge and whatever applies the edit. Phase 5 lands a real implementation
/// backed by `MCPClient` calling the plugin's `anglesite:apply-edit` tool; until then the wired
/// default is `LoggingEditRouter`.
public protocol EditRouter: Sendable {
    func apply(_ message: EditMessage) async -> EditReply
}

/// Resolves an optional configured router to a router that's always safe to call —
/// falls back to `LoggingEditRouter` (fails safe, never silently drops an edit) when
/// nothing was wired. Named and tested separately from `ComponentCanvasView.makeNSView`
/// so the fallback behavior has coverage independent of the untestable NSViewRepresentable.
public func resolveEditRouter(_ configured: EditRouter?) -> EditRouter {
    configured ?? LoggingEditRouter()
}

/// Development default: logs the message to `LogCenter` (so it shows up in the Debug pane) and
/// replies `.failed` with a "not wired yet" hint. Lets `PreviewView` ship the bridge end-to-end
/// before the Phase 5 server-side patcher exists.
public struct LoggingEditRouter: EditRouter {
    private let logCenter: LogCenter

    public init(logCenter: LogCenter = .shared) {
        self.logCenter = logCenter
    }

    public func apply(_ message: EditMessage) async -> EditReply {
        let target = message.selector.map { "\($0)" } ?? message.component.map { "\($0)" } ?? "?"
        await logCenter.append(
            source: "bridge",
            stream: .stdout,
            text: "(stub) would apply \(message.op) on \(target) at \(message.path) [id=\(message.id)]"
        )
        return EditReply(
            id: message.id,
            status: .failed,
            message: "apply-edit routing not yet wired — Phase 5 lands the server-side patcher"
        )
    }
}
