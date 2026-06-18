import Testing
import Foundation
@testable import AnglesiteCore

@Suite("MCPApplyEditRouter cancellation")
struct MCPApplyEditRouterCancelTests {
    @Test("a CancellationError from the tool caller maps to a clean failed reply")
    func mapsCancellation() async {
        let router = MCPApplyEditRouter(toolCaller: { _, _ in throw CancellationError() })
        let msg = EditMessage(id: "e1", type: .applyEdit, path: "/about", selector: .object([:]), op: "apply-instruction", value: .string("x"))
        let reply = await router.apply(msg)
        #expect(reply.status == .failed)
        #expect(reply.message == "canceled")
    }
}
