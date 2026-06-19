import Testing
import Foundation
@testable import AnglesiteCore

// MARK: - Private helpers (scoped to this file)

/// A gate that parks an async task until explicitly released.
/// `wait()` uses a `CheckedContinuation<Void, Never>` so it does NOT check for
/// cancellation — the parked task stays parked until `release()` is called.
private actor EditGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuation = cont
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Counts how many times the injected tool caller was invoked.
private actor EditCallRecorder {
    private(set) var count = 0
    func bump() { count += 1 }
}

// MARK: - Test suite

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

    @Test("a pre-cancelled apply returns canceled without calling the tool")
    func preCancelledSkipsTool() async {
        let recorder = EditCallRecorder()
        let router = MCPApplyEditRouter(toolCaller: { _, _ in
            await recorder.bump()
            return MCPClient.ToolCallResult(content: [], isError: false)
        })
        let msg = EditMessage(id: "e2", type: .applyEdit, path: "/about", selector: .object([:]), op: "apply-instruction", value: .string("x"))
        let gate = EditGate()
        let task = Task { () -> EditReply in
            await gate.wait()          // parked until released; cancel lands while parked
            return await router.apply(msg)
        }
        task.cancel()
        await gate.release()
        let reply = await task.value
        #expect(reply.status == .failed)
        #expect(reply.message == "canceled")
        #expect(await recorder.count == 0)   // toolCaller never called
    }
}
