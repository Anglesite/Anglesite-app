import Foundation
@testable import AnglesiteCore

/// A `SiteFileWatching` fake the test can poke: it captures the batch handler and the watched
/// root, and records start/stop so runtime wiring can be asserted.
final class ControllableWatcher: SiteFileWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (FileChangeBatch) -> Void)?
    private(set) var startedRoot: URL?
    private(set) var stopCount = 0

    func start(root: URL, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws {
        lock.lock()
        startedRoot = root
        handler = onBatch
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopCount += 1
        handler = nil
        lock.unlock()
    }

    var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedRoot != nil
    }

    func deliver(_ batch: FileChangeBatch) {
        lock.lock()
        let h = handler
        lock.unlock()
        h?(batch)
    }
}
