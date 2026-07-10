import Foundation
import Testing
@testable import AnglesiteBridge
import AnglesiteCore

// `AnglesiteScriptHandler.dispatch`'s routing logic is now `AnglesiteMessageDispatcher.dispatch`,
// tested in `AnglesiteBridgeCoreTests` (portable). What's left here is `AnglesiteScriptHandler`'s
// own remaining code: the deprecated `handle(body:via:)` back-compat shim, which only exists on
// this WKWebView-specific type.
struct AnglesiteScriptHandlerTests {
    private func validEditBody() -> [String: Any] {
        [
            "id": "e-99",
            "type": "anglesite:apply-edit",
            "path": "/contact/",
            "selector": [
                "tag": "H1",
                "classes": [] as [String],
                "nthChild": 1,
            ] as [String: Any],
            "op": "replace-text",
            "value": "New heading",
        ]
    }

    // The deprecated `handle(body:via:)` shim exists so out-of-tree adopters of the old
    // signature get a fix-it. These tests verify the migration path still routes correctly.
    @Test("Deprecated handle() forwards apply-edit and returns success") func deprecatedHandle_routesApplyEdit() async {
        let router = RecordingRouter(reply: EditReply(id: "e-99", status: .applied, message: "done"))
        let result = await deprecatedHandle(body: validEditBody(), via: router)
        guard case .success(let reply) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(reply.id == "e-99")
        #expect(reply.status == .applied)
    }

    @Test("Deprecated handle() preserves the legacy unknown-type failure mode") func deprecatedHandle_unknownType() async {
        var body = validEditBody()
        body["type"] = "anglesite:not-real"
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await deprecatedHandle(body: body, via: router)
        guard case .failure(.unknownType("anglesite:not-real")) = result else {
            Issue.record("expected .failure(.unknownType), got \(result)")
            return
        }
    }

    // Wrap the deprecated call so the deprecation warning lands once at the wrapper level
    // rather than per-call-site. Swift Testing's `@available` propagation handles this.
    @available(*, deprecated)
    private func deprecatedHandle(body: Any, via router: EditRouter) async -> Result<EditReply, EditMessage.DecodeError> {
        await AnglesiteScriptHandler.handle(body: body, via: router)
    }
}

private actor RecordingRouter: EditRouter {
    private(set) var received: [EditMessage] = []
    private let reply: EditReply
    init(reply: EditReply) { self.reply = reply }
    func apply(_ message: EditMessage) async -> EditReply {
        received.append(message)
        return reply
    }
}
