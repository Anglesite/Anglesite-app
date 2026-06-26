import Foundation

/// Serializes `astro build` runs against the shared `Resources/Template/` working tree.
///
/// Multiple render-smoke suites (`PersonalTypeRenderSmokeTests`, `FeedsRenderSmokeTests`, …)
/// each build the *same* template directory and `rm -rf dist` around their build. Swift Testing
/// runs suites in parallel, so without coordination one suite's `rm -rf dist` deletes another's
/// in-flight output and that build fails. This actor gives those builds mutual exclusion: each
/// wraps its build in `TemplateBuildSerializer.shared.serialize { … }` so only one runs at a time.
///
/// It is a genuine async lock (not just an actor method — actor reentrancy would let calls
/// interleave at the build's `await`), implemented with a one-slot gate and a FIFO waiter queue.
public actor TemplateBuildSerializer {
    public static let shared = TemplateBuildSerializer()

    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    private func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Run `body` while holding the shared template-build lock; other callers wait their turn.
    public func serialize<T>(_ body: () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }
}
