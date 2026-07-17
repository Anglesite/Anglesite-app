import Foundation
import Testing
@testable import AnglesiteCore

@Suite("Activity assertion")
struct ActivityAssertionTests {
    @Test("release invokes the release action exactly once")
    func releaseInvokesActionOnce() {
        let calls = LockedCount()
        let lease = ActivityAssertion.Lease(onRelease: { calls.increment() })

        lease.release()
        #expect(calls.value == 1)
    }

    @Test("a lease releases at most once, even called repeatedly")
    func idempotentRelease() {
        let calls = LockedCount()
        let lease = ActivityAssertion.Lease(onRelease: { calls.increment() })

        lease.release()
        lease.release()
        lease.release()

        #expect(calls.value == 1)
    }

    @Test("deinit releases an un-released lease as a safety net")
    func deinitReleases() {
        let calls = LockedCount()
        do {
            _ = ActivityAssertion.Lease(onRelease: { calls.increment() })
        }
        #expect(calls.value == 1)
    }

    @Test("deinit does not double-release an already-released lease")
    func deinitAfterExplicitReleaseDoesNotDoubleRelease() {
        let calls = LockedCount()
        do {
            let lease = ActivityAssertion.Lease(onRelease: { calls.increment() })
            lease.release()
        }
        #expect(calls.value == 1)
    }

    @Test("begin(reason:) returns a lease that can be released without crashing")
    func beginReturnsAReleasableLease() {
        // Exercises the real #os(macOS)/off-macOS branches in begin(_:) — on macOS this makes a
        // real ProcessInfo.beginActivity/endActivity round trip; off-macOS it's a no-op. Either
        // way, a caller that never inspects the token shouldn't be able to observe the difference.
        let lease = ActivityAssertion.begin(reason: "test")
        lease.release()
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
