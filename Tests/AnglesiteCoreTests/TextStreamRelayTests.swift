import Testing
import Foundation
@testable import AnglesiteCore

/// `TextStreamRelay` is the consumer-facing half of ``FoundationModelAssistant``'s one-shot
/// (`generate`/`textStream`) drain-and-detach cancellation: it gates text delivery and enforces
/// once-only terminal transitions, with no dependency on the live model — so these run on any
/// toolchain. It mirrors ``TurnRelay`` for the throwing `String` stream the one-shot path yields.
@Suite("TextStreamRelay")
struct TextStreamRelayTests {

    private struct SampleError: Error, Equatable { let message: String }

    /// Drive `body` against a fresh relay, then collect the consumer stream's chunks plus any
    /// thrown terminal error. The relay must reach a terminal state (`complete`/`fail`/`detach`)
    /// or this would hang — which is itself the contract under test.
    private func collect(_ body: (TextStreamRelay) -> Void) async -> (chunks: [String], error: Error?) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        let relay = TextStreamRelay(continuation)
        body(relay)
        var chunks: [String] = []
        do {
            for try await chunk in stream { chunks.append(chunk) }
            return (chunks, nil)
        } catch {
            return (chunks, error)
        }
    }

    @Test("delivers text in order, then a terminal complete with no error")
    func deliversThenCompletes() async {
        let result = await collect { relay in
            relay.deliver("Hello")
            relay.deliver(" world")
            relay.complete()
        }
        #expect(result.chunks == ["Hello", " world"])
        #expect(result.error == nil)
    }

    @Test("detach stops delivery and ends without error")
    func detachStopsDelivery() async {
        let result = await collect { relay in
            relay.deliver("partial")
            // The consumer dropped the stream. Chunks arriving afterwards from the still-draining
            // model task must NOT reach the consumer, and the drain's own `complete()` is a no-op.
            relay.detach()
            relay.deliver("more")
            relay.complete()
        }
        #expect(result.chunks == ["partial"])
        #expect(result.error == nil)
    }

    @Test("fail surfaces the error to the consumer")
    func failSurfacesError() async {
        let result = await collect { relay in
            relay.deliver("partial")
            relay.fail(SampleError(message: "boom"))
        }
        #expect(result.chunks == ["partial"])
        #expect((result.error as? SampleError) == SampleError(message: "boom"))
    }

    @Test("complete is once-only and suppresses a later fail")
    func completeIsOnceOnly() async {
        let result = await collect { relay in
            relay.complete()
            relay.fail(SampleError(message: "late"))
        }
        #expect(result.chunks.isEmpty)
        #expect(result.error == nil)
    }

    @Test("fail after detach is suppressed — no error leaks to a detached consumer")
    func failAfterDetachIsSuppressed() async {
        let result = await collect { relay in
            relay.deliver("partial")
            relay.detach()
            relay.fail(SampleError(message: "after detach"))
        }
        #expect(result.chunks == ["partial"])
        #expect(result.error == nil)
    }

    @Test("detach after complete is a no-op")
    func detachAfterCompleteIsNoOp() async {
        let result = await collect { relay in
            relay.complete()
            relay.detach()
        }
        #expect(result.chunks.isEmpty)
        #expect(result.error == nil)
    }
}
