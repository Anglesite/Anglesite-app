import Testing
import Foundation
@testable import AnglesiteCore

struct EditReplyAndRouterTests {

    // MARK: EditReply JSON encoding

    @Test("Edit reply encodes applied with message") func editReplyEncodesAppliedWithMessage() throws {
        let reply = EditReply(id: "e-1", status: .applied, message: "ok")
        let json = try JSONEncoder().encode(reply)
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(decoded?["id"] as? String == "e-1")
        #expect(decoded?["status"] as? String == "applied")
        #expect(decoded?["message"] as? String == "ok")
    }

    @Test("Edit reply encodes failure and ambiguous status strings") func editReplyEncodesFailureAndAmbiguousStatusStrings() throws {
        let cases: [(EditReply.Status, String)] = [(.applied, "applied"), (.failed, "failed"), (.ambiguous, "ambiguous")]
        for (status, raw) in cases {
            let reply = EditReply(id: "e", status: status, message: nil)
            let json = try JSONEncoder().encode(reply)
            let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
            #expect(decoded?["status"] as? String == raw, "status \(status) should encode as \"\(raw)\"")
        }
    }

    // MARK: LoggingEditRouter

    @Test("Logging edit router replies failed with correlated ID") func loggingEditRouterRepliesFailedWithCorrelatedID() async {
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

    @Test("Logging edit router appends to log center") func loggingEditRouterAppendsToLogCenter() async {
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

    // MARK: resolveEditRouter

    private struct RecordingEditRouter: EditRouter {
        func apply(_ message: EditMessage) async -> EditReply {
            EditReply(id: message.id, status: .applied, message: "recorded")
        }
    }

    @Test("resolveEditRouter passes through a configured router") func resolveEditRouterPassesThroughConfigured() async {
        let configured = RecordingEditRouter()
        let resolved = resolveEditRouter(configured)
        let msg = EditMessage(
            id: "e-1", type: .applyEdit, path: "/",
            selector: .object(["tag": .string("H1"), "classes": .array([]), "nthChild": .int(1)]),
            op: "replace-text", value: .string("Hi")
        )
        let reply = await resolved.apply(msg)
        #expect(reply.message == "recorded", "expected the configured router to handle the call, not a fallback")
    }

    @Test("resolveEditRouter falls back to LoggingEditRouter when nil") func resolveEditRouterFallsBackWhenNil() async {
        let resolved = resolveEditRouter(nil)
        let msg = EditMessage(
            id: "e-2", type: .applyEdit, path: "/",
            selector: .object(["tag": .string("H1"), "classes": .array([]), "nthChild": .int(1)]),
            op: "replace-text", value: .string("Hi")
        )
        let reply = await resolved.apply(msg)
        #expect(reply.status == .failed, "the fallback should be a LoggingEditRouter, which always replies failed")
    }

    // MARK: parseStructured piggybacked model

    @Test("parseStructured decodes a piggybacked model")
    func parseStructuredDecodesModel() {
        let json = """
        {"type":"anglesite:edit-applied","id":"1","file":"src/components/Card.astro","range":{"start":0,"end":1},"model":\(ComponentModelTests.fixture)}
        """
        let parsed = MCPApplyEditRouter.parseStructured(json)
        #expect(parsed?.model?.path == "src/components/Card.astro")
    }
}
