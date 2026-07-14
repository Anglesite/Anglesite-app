import Foundation
import Testing
@testable import AnglesiteCore

@Suite("Sudden termination controller")
struct SuddenTerminationControllerTests {
    @Test("overlapping leases bracket ProcessInfo calls once")
    func overlappingLeases() {
        let calls = LockedCalls()
        let controller = SuddenTerminationController(
            disable: { calls.recordDisable() },
            enable: { calls.recordEnable() }
        )

        let first = controller.acquire()
        let second = controller.acquire()
        #expect(controller.activeLeaseCount == 2)
        #expect(calls.snapshot.disables == 1)
        #expect(calls.snapshot.enables == 0)

        first.release()
        #expect(controller.activeLeaseCount == 1)
        #expect(calls.snapshot.disables == 1)
        #expect(calls.snapshot.enables == 0)

        second.release()
        #expect(controller.activeLeaseCount == 0)
        #expect(calls.snapshot.disables == 1)
        #expect(calls.snapshot.enables == 1)
    }

    @Test("a lease releases at most once")
    func idempotentRelease() {
        let calls = LockedCalls()
        let controller = SuddenTerminationController(
            disable: { calls.recordDisable() },
            enable: { calls.recordEnable() }
        )
        let lease = controller.acquire()

        lease.release()
        lease.release()

        #expect(controller.activeLeaseCount == 0)
        #expect(calls.snapshot.disables == 1)
        #expect(calls.snapshot.enables == 1)
    }
}

private final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var disables = 0
    private var enables = 0

    var snapshot: (disables: Int, enables: Int) {
        lock.withLock { (disables, enables) }
    }

    func recordDisable() {
        lock.withLock { disables += 1 }
    }

    func recordEnable() {
        lock.withLock { enables += 1 }
    }
}
