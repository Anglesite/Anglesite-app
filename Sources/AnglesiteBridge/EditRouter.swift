import Foundation
import AnglesiteCore

/// What the bridge says back to the overlay after handling an `EditMessage`. The struct is
/// `Encodable` because it gets `JSONEncoder()`'d straight into a `evaluateJavaScript` call —
/// `window.anglesite?._handleReply?.(<this object>)` — for the JS side to correlate via `id`.
public struct EditReply: Sendable, Equatable, Encodable {
    public let id: String
    public let status: Status
    /// Human-readable detail. Always present for `.failed` / `.ambiguous`; optional for `.applied`.
    public let message: String?

    public enum Status: String, Sendable, Equatable, Encodable {
        case applied, failed, ambiguous
    }

    public init(id: String, status: Status, message: String?) {
        self.id = id
        self.status = status
        self.message = message
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
