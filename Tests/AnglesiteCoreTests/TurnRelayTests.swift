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

    /// Exercises the actual race the lock guards: a draining producer (`deliver`×N then `complete`)
    /// against a consumer-initiated `cancel`, with the consumer reading concurrently. The sequential
    /// tests above finish all relay calls before the stream is read, so they never reach this path.
    /// Repeated trials make a torn read or missing-lock crash likely to surface; each trial asserts
    /// the consumer never hangs, sees an in-order prefix of the deltas, and ends with exactly one
    /// terminal event (`.turnComplete` or `.cancelled` — whichever won the race).
    @Test("concurrent deliver/complete vs cancel terminates with one terminal and ordered deltas")
    func concurrentDeliverCancelRace() async {
        let deltaCount = 100
        for _ in 0..<200 {
            let (stream, continuation) = AsyncStream.makeStream(of: AssistantEvent.self)
            let relay = TurnRelay(continuation)

            async let collected: [AssistantEvent] = {
                var events: [AssistantEvent] = []
                for await event in stream { events.append(event) }
                return events
            }()

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for i in 0..<deltaCount { relay.deliver(.textDelta(String(i))) }
                    relay.complete(.turnComplete(nil))
                }
                group.addTask { relay.cancel() }
            }

            let events = await collected
            // Exactly one terminal event, and it is last.
            let terminals = events.filter {
                if case .turnComplete = $0 { return true }
                if case .cancelled = $0 { return true }
                if case .failed = $0 { return true }
                return false
            }
            #expect(terminals.count == 1)
            if let last = events.last {
                let lastIsTerminal: Bool = {
                    if case .turnComplete = last { return true }
                    if case .cancelled = last { return true }
                    return false
                }()
                #expect(lastIsTerminal)
            }
            // The text deltas that survived the race are a contiguous, in-order prefix of 0,1,2,…
            let deltas: [String] = events.compactMap {
                if case .textDelta(let text) = $0 { return text }
                return nil
            }
            for (i, text) in deltas.enumerated() {
                #expect(text == String(i))
            }
        }
    }
}
