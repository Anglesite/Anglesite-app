import Testing
import Foundation
@testable import AnglesiteCore

/// `TurnRelay` is the consumer-facing half of ``FoundationModelAssistant``'s drain-and-detach
/// cancellation: it gates event delivery and enforces once-only terminal transitions, with no
/// dependency on the live model — so these run on any toolchain.
@Suite("TurnRelay")
struct TurnRelayTests {

    /// Drive `body` against a fresh relay, then collect everything the consumer stream emits.
    /// The relay must reach a terminal state (`complete`/`cancel`/`detach`) or this would hang —
    /// which is itself the contract under test.
    private func collect(_ body: (TurnRelay) -> Void) async -> [AssistantEvent] {
        let (stream, continuation) = AsyncStream.makeStream(of: AssistantEvent.self)
        let relay = TurnRelay(continuation)
        body(relay)
        var events: [AssistantEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("delivers events in order, then a terminal complete")
    func deliversThenCompletes() async {
        let events = await collect { relay in
            relay.deliver(.started(model: "On-Device", toolNames: []))
            relay.deliver(.textDelta("Hello"))
            relay.deliver(.textDelta(" world"))
            relay.complete(.turnComplete(nil))
        }
        #expect(events == [
            .started(model: "On-Device", toolNames: []),
            .textDelta("Hello"),
            .textDelta(" world"),
            .turnComplete(nil),
        ])
    }

    @Test("cancel emits .cancelled and suppresses later deliver/complete")
    func cancelStopsDelivery() async {
        let events = await collect { relay in
            relay.deliver(.textDelta("partial"))
            relay.cancel()
            // These arrive from the still-draining model stream after the user cancelled — they
            // must NOT reach the consumer, and must NOT produce a second terminal event.
            relay.deliver(.textDelta("more"))
            relay.complete(.turnComplete(nil))
        }
        #expect(events == [.textDelta("partial"), .cancelled])
    }

    @Test("complete is once-only")
    func completeIsOnceOnly() async {
        let events = await collect { relay in
            relay.complete(.turnComplete(nil))
            relay.complete(.failed(message: "late"))
        }
        #expect(events == [.turnComplete(nil)])
    }

    @Test("detach ends the stream silently with no terminal event")
    func detachIsSilent() async {
        let events = await collect { relay in
            relay.deliver(.textDelta("partial"))
            relay.detach()
            relay.deliver(.textDelta("more"))
            relay.complete(.turnComplete(nil))
        }
        #expect(events == [.textDelta("partial")])
    }

    @Test("cancel after a turn already ended is a no-op")
    func cancelAfterEndIsNoOp() async {
        let events = await collect { relay in
            relay.complete(.turnComplete(nil))
            relay.cancel()
        }
        #expect(events == [.turnComplete(nil)])
    }
}
