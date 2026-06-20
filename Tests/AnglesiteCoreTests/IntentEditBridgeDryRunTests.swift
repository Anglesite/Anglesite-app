import Testing
import Foundation
@testable import AnglesiteCore

@Suite("IntentEditBridge dry-run")
struct IntentEditBridgeDryRunTests {
    actor Recorder: EditRouter {
        private(set) var messages: [EditMessage] = []
        func apply(_ message: EditMessage) async -> EditReply {
            messages.append(message)
            return EditReply(id: message.id, status: .preview, message: nil, before: "a", after: "b", op: message.op)
        }
    }

    @Test("applyEdit forwards dryRun to the EditMessage")
    func forwardsDryRun() async {
        let rec = Recorder()
        let bridge = IntentEditBridge(routerProvider: { _ in rec }, makeID: { "fixed" })
        _ = await bridge.applyEdit(siteID: "s", filePath: "/a/", selector: .object(["tag": .string("h1")]),
                                   op: "edit-style", value: .object(["property": .string("color"), "value": .string("teal")]),
                                   dryRun: true)
        let sent = await rec.messages
        #expect(sent.count == 1)
        #expect(sent.first?.dryRun == true)
    }
}
