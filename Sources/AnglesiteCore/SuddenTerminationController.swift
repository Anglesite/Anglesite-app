import Foundation

/// Process-wide reference counting for work that must finish before macOS may suddenly terminate
/// Anglesite. Callers retain the returned lease for exactly as long as their critical state exists;
/// releasing (or deinitializing) the last lease re-enables sudden termination.
public final class SuddenTerminationController: @unchecked Sendable {
    public static let shared = SuddenTerminationController()

    public final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var controller: SuddenTerminationController?

        fileprivate init(controller: SuddenTerminationController) {
            self.controller = controller
        }

        /// Releases this lease once. Repeated calls are harmless.
        public func release() {
            lock.lock()
            let controller = self.controller
            self.controller = nil
            lock.unlock()
            controller?.releaseLease()
        }

        deinit {
            release()
        }
    }

    private let lock = NSLock()
    private let disable: @Sendable () -> Void
    private let enable: @Sendable () -> Void
    private var leaseCount = 0

    public convenience init() {
        self.init(
            disable: { SuddenTerminationController.disableProcessSuddenTermination() },
            enable: { SuddenTerminationController.enableProcessSuddenTermination() }
        )
    }

    /// Closures are injectable so the balancing invariant can be tested without changing the test
    /// runner's own sudden-termination state.
    public init(
        disable: @escaping @Sendable () -> Void,
        enable: @escaping @Sendable () -> Void
    ) {
        self.disable = disable
        self.enable = enable
    }

    public var activeLeaseCount: Int {
        lock.withLock { leaseCount }
    }

    public func acquire() -> Lease {
        lock.lock()
        if leaseCount == 0 {
            disable()
        }
        leaseCount += 1
        lock.unlock()
        return Lease(controller: self)
    }

    private func releaseLease() {
        lock.lock()
        guard leaseCount > 0 else {
            lock.unlock()
            assertionFailure("Sudden-termination lease count became unbalanced")
            return
        }
        leaseCount -= 1
        let shouldEnable = leaseCount == 0
        if shouldEnable {
            enable()
        }
        lock.unlock()
    }

    private static func disableProcessSuddenTermination() {
        #if os(macOS)
        ProcessInfo.processInfo.disableSuddenTermination()
        #endif
    }

    private static func enableProcessSuddenTermination() {
        #if os(macOS)
        ProcessInfo.processInfo.enableSuddenTermination()
        #endif
    }
}
