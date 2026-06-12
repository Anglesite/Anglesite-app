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

    public struct ImageResult: Sendable, Equatable, Encodable {
        public let src: String
        public let srcset: String?

        public init(src: String, srcset: String?) {
            self.src = src
            self.srcset = srcset
        }
    }

    public enum Status: String, Sendable, Equatable, Encodable {
        case applied, failed, ambiguous
    }

    public init(
        id: String,
        status: Status,
        message: String?,
        file: String? = nil,
        commit: String? = nil,
        result: ImageResult? = nil
    ) {
        self.id = id
        self.status = status
        self.message = message
        self.file = file
        self.commit = commit
        self.result = result
    }
}

/// The seam between the JS bridge and whatever applies the edit. Phase 5 lands a real implementation
/// backed by `MCPClient` calling the plugin's `anglesite:apply-edit` tool; until then the wired
/// default is `LoggingEditRouter`.
public protocol EditRouter: Sendable {
    func apply(_ message: EditMessage) async -> EditReply
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
        await logCenter.append(
            source: "bridge",
            stream: .stdout,
            text: "(stub) would apply \(message.op) on \(message.selector) at \(message.path) [id=\(message.id)]"
        )
        return EditReply(
            id: message.id,
            status: .failed,
            message: "apply-edit routing not yet wired — Phase 5 lands the server-side patcher"
        )
    }
}
