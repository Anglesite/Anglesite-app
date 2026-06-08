import Testing
import Foundation
@testable import AnglesiteBridge
import AnglesiteCore

struct EditReplyAndRouterTests {

    // MARK: EditReply JSON encoding

    @Test func `Edit reply encodes applied with message`() throws {
        let reply = EditReply(id: "e-1", status: .applied, message: "ok")
        let json = try JSONEncoder().encode(reply)
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(decoded?["id"] as? String == "e-1")
        #expect(decoded?["status"] as? String == "applied")
        #expect(decoded?["message"] as? String == "ok")
    }

    @Test func `Edit reply encodes failure and ambiguous status strings`() throws {
        let cases: [(EditReply.Status, String)] = [(.applied, "applied"), (.failed, "failed"), (.ambiguous, "ambiguous")]
        for (status, raw) in cases {
            let reply = EditReply(id: "e", status: status, message: nil)
            let json = try JSONEncoder().encode(reply)
            let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
            #expect(decoded?["status"] as? String == raw, "status \(status) should encode as \"\(raw)\"")
        }
    }

    // MARK: LoggingEditRouter

    @Test func `Logging edit router replies failed with correlated ID`() async {
        let center = LogCenter()
        let router = LoggingEditRouter(logCenter: center)
        let msg = EditMessage(
            id: "e-42", type: .applyEdit, path: "/",
            selector: .object(["tag": .string("H1"), "classes": .array([]), "nthChild": .int(1)]),
            op: "replace-text", value: .string("Hi")
        )
        let reply = await router.apply(msg)
        #expect(reply.id == "e-42")
        #expect(reply.status == .failed)
        #expect(reply.message != nil)
        #expect(reply.message?.lowercased().contains("phase 5") ?? false,
                "reply message should explain that the routing isn't wired yet — got: \(reply.message ?? "nil")")
    }

    @Test func `Logging edit router appends to log center`() async {
        let center = LogCenter()
        let router = LoggingEditRouter(logCenter: center)
        let msg = EditMessage(
            id: "e-1", type: .applyEdit, path: "/about/",
            selector: .object(["tag": .string("P"), "classes": .array([]), "nthChild": .int(1)]),
            op: "replace-text", value: .string("x")
        )
        _ = await router.apply(msg)
        let lines = await center.snapshot().filter { $0.source == "bridge" }
        #expect(!lines.isEmpty, "expected at least one bridge log line")
        let text = lines.last?.text ?? ""
        #expect(text.contains("replace-text") && text.contains("/about/"),
                "log line should reflect the op + path — got: \(text)")
    }
}
