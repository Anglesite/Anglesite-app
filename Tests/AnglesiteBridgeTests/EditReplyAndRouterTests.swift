import XCTest
@testable import AnglesiteBridge
import AnglesiteCore

final class EditReplyAndRouterTests: XCTestCase {

    // MARK: EditReply JSON encoding

    func testEditReplyEncodesAppliedWithMessage() throws {
        let reply = EditReply(id: "e-1", status: .applied, message: "ok")
        let json = try JSONEncoder().encode(reply)
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(decoded?["id"] as? String, "e-1")
        XCTAssertEqual(decoded?["status"] as? String, "applied")
        XCTAssertEqual(decoded?["message"] as? String, "ok")
    }

    func testEditReplyEncodesFailureAndAmbiguousStatusStrings() throws {
        let cases: [(EditReply.Status, String)] = [(.applied, "applied"), (.failed, "failed"), (.ambiguous, "ambiguous")]
        for (status, raw) in cases {
            let reply = EditReply(id: "e", status: status, message: nil)
            let json = try JSONEncoder().encode(reply)
            let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
            XCTAssertEqual(decoded?["status"] as? String, raw, "status \(status) should encode as \"\(raw)\"")
        }
    }

    // MARK: LoggingEditRouter

    func testLoggingEditRouterRepliesFailedWithCorrelatedID() async {
        let center = LogCenter()
        let router = LoggingEditRouter(logCenter: center)
        let msg = EditMessage(
            id: "e-42", type: .applyEdit, path: "/",
            selector: .object(["tag": .string("H1"), "classes": .array([]), "nthChild": .int(1)]),
            op: "set-text", value: .string("Hi")
        )
        let reply = await router.apply(msg)
        XCTAssertEqual(reply.id, "e-42")
        XCTAssertEqual(reply.status, .failed)
        XCTAssertNotNil(reply.message)
        XCTAssertTrue(reply.message?.lowercased().contains("phase 5") ?? false,
                      "reply message should explain that the routing isn't wired yet — got: \(reply.message ?? "nil")")
    }

    func testLoggingEditRouterAppendsToLogCenter() async {
        let center = LogCenter()
        let router = LoggingEditRouter(logCenter: center)
        let msg = EditMessage(
            id: "e-1", type: .applyEdit, path: "/about/",
            selector: .object(["tag": .string("P"), "classes": .array([]), "nthChild": .int(1)]),
            op: "set-text", value: .string("x")
        )
        _ = await router.apply(msg)
        let lines = await center.snapshot().filter { $0.source == "bridge" }
        XCTAssertFalse(lines.isEmpty, "expected at least one bridge log line")
        let text = lines.last?.text ?? ""
        XCTAssertTrue(text.contains("set-text") && text.contains("/about/"),
                      "log line should reflect the op + path — got: \(text)")
    }
}
