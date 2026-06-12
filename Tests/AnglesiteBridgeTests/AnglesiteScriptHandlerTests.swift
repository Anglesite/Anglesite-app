import Testing
@testable import AnglesiteBridge
import AnglesiteCore

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

    private func validVisibleElementsBody() -> [String: Any] {
        [
            "type": "anglesite:visible-elements",
            "elements": [
                [
                    "id": "v-1",
                    "tag": "H1",
                    "selector": [
                        "tag": "H1",
                        "classes": [] as [String],
                        "nthChild": 1,
                    ] as [String: Any],
                    "rect": ["x": 0, "y": 0, "width": 100, "height": 40] as [String: Any],
                    "text": "Heading",
                ] as [String: Any]
            ] as [Any],
        ]
    }

    @Test("Dispatch routes apply-edit and returns reply") func dispatchRoutesApplyEdit() async {
        let router = RecordingRouter(reply: EditReply(id: "e-99", status: .applied, message: "done"))
        let result = await AnglesiteScriptHandler.dispatch(body: validEditBody(), via: router)
        guard case .editReply(let reply) = result else {
            Issue.record("expected .editReply, got \(result)")
            return
        }
        #expect(reply.id == "e-99")
        #expect(reply.status == .applied)
        let received = await router.received
        #expect(received.count == 1)
        #expect(received.first?.id == "e-99")
        #expect(received.first?.op == "replace-text")
    }

    @Test("Dispatch rejects unknown message type") func dispatchRejectsUnknownType() async {
        var bad = validEditBody()
        bad["type"] = "anglesite:not-real"
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteScriptHandler.dispatch(body: bad, via: router)
        guard case .rejected(.unknownType(let t)) = result else {
            Issue.record("expected .rejected(.unknownType), got \(result)")
            return
        }
        #expect(t == "anglesite:not-real")
        let received = await router.received
        #expect(received.isEmpty, "router must not see undecodable input")
    }

    @Test("Dispatch rejects body that is not an object") func dispatchRejectsNonObject() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteScriptHandler.dispatch(body: "string", via: router)
        guard case .rejected(.notAnObject) = result else {
            Issue.record("expected .rejected(.notAnObject), got \(result)")
            return
        }
    }

    @Test("Dispatch reports missing type as missingType") func dispatchReportsMissingType() async {
        var body = validEditBody()
        body.removeValue(forKey: "type")
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteScriptHandler.dispatch(body: body, via: router)
        guard case .rejected(.missingType) = result else {
            Issue.record("expected .rejected(.missingType), got \(result)")
            return
        }
    }

    @Test("Dispatch forwards visible-elements to handler") func dispatchForwardsVisibleElements() async {
        let collector = ElementCollector()
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteScriptHandler.dispatch(
            body: validVisibleElementsBody(),
            via: router,
            onVisibleElements: { elements in await collector.append(elements) }
        )
        guard case .visibleElementsHandled = result else {
            Issue.record("expected .visibleElementsHandled, got \(result)")
            return
        }
        let captured = await collector.batches
        #expect(captured.count == 1)
        #expect(captured.first?.count == 1)
        #expect(captured.first?.first?.id == "v-1")
        let received = await router.received
        #expect(received.isEmpty, "router must not see a visible-elements message")
    }

    @Test("Dispatch drops visible-elements when no handler is installed") func dispatchDropsVisibleElementsWithoutHandler() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteScriptHandler.dispatch(
            body: validVisibleElementsBody(),
            via: router,
            onVisibleElements: nil
        )
        guard case .visibleElementsDropped = result else {
            Issue.record("expected .visibleElementsDropped, got \(result)")
            return
        }
    }

    @Test("Dispatch surfaces visible-elements decode failures") func dispatchSurfacesVisibleElementsDecodeFailure() async {
        var body = validVisibleElementsBody()
        body.removeValue(forKey: "elements")
        let collector = ElementCollector()
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteScriptHandler.dispatch(
            body: body,
            via: router,
            onVisibleElements: { elements in await collector.append(elements) }
        )
        guard case .rejected(.visibleElementsDecode(.missingField("elements"))) = result else {
            Issue.record("expected .rejected(.visibleElementsDecode(.missingField(elements))), got \(result)")
            return
        }
        let captured = await collector.batches
        #expect(captured.isEmpty)
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

private actor ElementCollector {
    private(set) var batches: [[VisibleElement]] = []
    func append(_ batch: [VisibleElement]) { batches.append(batch) }
}
