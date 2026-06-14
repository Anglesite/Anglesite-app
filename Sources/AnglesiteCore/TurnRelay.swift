import Foundation

/// Relays one conversational turn's ``AssistantEvent`` values to a consumer `AsyncStream`, so
/// ``FoundationModelAssistant`` can stop *delivering* on cancel without cancelling the model stream
/// (cancelling Apple's `streamResponse` mid-flight traps the process). Terminal transitions
/// (`complete`/`cancel`/`detach`) are once-only and thread-safe — the draining task and `cancel()`
/// race to end the same turn. Ungated, so it unit-tests on any toolchain (incl. CI without the model).
final class TurnRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: AsyncStream<AssistantEvent>.Continuation

    init(_ continuation: AsyncStream<AssistantEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Forward a non-terminal event (`.started`, `.textDelta`) to the consumer, unless the turn has
    /// already ended (cancelled, detached, or completed). A no-op after the turn ends — so deltas
    /// from the still-draining model stream after a cancel are silently dropped.
    func deliver(_ event: AssistantEvent) {
        lock.lock()
        let done = finished
        lock.unlock()
        // A `yield` after `finish()` is a harmless no-op, so the brief unlocked window before this
        // line can't double-deliver; the lock is only for `finished`'s memory visibility.
        if !done { continuation.yield(event) }
    }

    /// End the turn with a terminal event the model produced (`.turnComplete`/`.failed`).
    /// Ignored if the turn already ended (e.g. the consumer cancelled first).
    func complete(_ event: AssistantEvent) { end(emitting: event) }

    /// Consumer-initiated cancel: end the turn with `.cancelled`. Ignored if already ended.
    func cancel() { end(emitting: .cancelled) }

    /// The consumer dropped the stream: end silently with no terminal event. Ignored if already ended.
    func detach() { end(emitting: nil) }

    /// Once-only terminal transition: the draining task (`complete`) and the actor (`cancel`/`detach`)
    /// race to end the same turn; the first wins and emits its event, the rest are no-ops.
    private func end(emitting event: AssistantEvent?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        if let event { continuation.yield(event) }
        continuation.finish()
    }
}
