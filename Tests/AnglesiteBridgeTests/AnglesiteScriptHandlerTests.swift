import Testing
@testable import AnglesiteBridge
import AnglesiteCore

struct AnglesiteScriptHandlerTests {
    private func validBody() -> [String: Any] {
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

    @Test func `Handle valid body routes and returns reply`() async {
        let router = RecordingRouter(reply: EditReply(id: "e-99", status: .applied, message: "done"))
        let result = await AnglesiteScriptHandler.handle(body: validBody(), via: router)
        guard case .success(let reply) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(reply.id == "e-99")
        #expect(reply.status == .applied)
        let received = await router.received
        #expect(received.count == 1)
        #expect(received.first?.id == "e-99")
        #expect(received.first?.op == "replace-text")
    }

    @Test func `Handle invalid body returns decode error and does not route`() async {
        // Wrong type at the type field — strict decode rejects it before any routing.
        var bad = validBody()
        bad["type"] = "anglesite:not-real"
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteScriptHandler.handle(body: bad, via: router)
        guard case .failure(let err) = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        #expect(err == .unknownType("anglesite:not-real"))
        let received = await router.received
        #expect(received.isEmpty, "router must not see undecodable input")
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
