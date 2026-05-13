import XCTest
@testable import AnglesiteBridge
import AnglesiteCore

final class AnglesiteScriptHandlerTests: XCTestCase {
    private func validBody() -> [String: Any] {
        [
            "id": "e-99",
            "type": "anglesite:apply-edit",
            "path": "/contact/",
            "selector": "h1",
            "op": "set-text",
            "value": "New heading",
        ]
    }

    func testHandleValidBodyRoutesAndReturnsReply() async {
        let router = RecordingRouter(reply: EditReply(id: "e-99", status: .applied, message: "done"))
        let result = await AnglesiteScriptHandler.handle(body: validBody(), via: router)
        guard case .success(let reply) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(reply.id, "e-99")
        XCTAssertEqual(reply.status, .applied)
        let received = await router.received
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.id, "e-99")
        XCTAssertEqual(received.first?.op, "set-text")
    }

    func testHandleInvalidBodyReturnsDecodeErrorAndDoesNotRoute() async {
        // Wrong type at the type field — strict decode rejects it before any routing.
        var bad = validBody()
        bad["type"] = "anglesite:not-real"
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteScriptHandler.handle(body: bad, via: router)
        guard case .failure(let err) = result else {
            return XCTFail("expected .failure, got \(result)")
        }
        XCTAssertEqual(err, .unknownType("anglesite:not-real"))
        let received = await router.received
        XCTAssertTrue(received.isEmpty, "router must not see undecodable input")
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
