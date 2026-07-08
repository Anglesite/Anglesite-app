import Foundation

/// A process-wide "one instance per key" cache: the first caller for a key constructs the value,
/// every later (or concurrent) caller for that key gets that same instance back.
///
/// This exists for types whose internal synchronization is per-instance, so correctness depends on
/// everyone using the *same* instance for the same underlying resource. The concrete case (#573):
/// apple/containerization's `ImageStore` guards multi-step operations with an `AsyncLock` stored on
/// the instance — two `ImageStore(path:)` constructions over the same store directory hold two
/// unrelated locks, letting `cleanUpOrphanedBlobs()` through one instance delete blobs that a
/// `load(from:)` through another has ingested but not yet referenced. Keying instances by store
/// path restores "one lock per store directory". The consumer (`SharedImageStore` in
/// AnglesiteContainer) can't be CI-tested — CI never compiles that module — so the sharing
/// semantics live here, in pure Foundation, under `swift test`.
///
/// Entries live for the process lifetime; there is no eviction (the expected population is one or
/// two store paths). The lock is held while `make` runs, which is what guarantees the factory runs
/// at most once per key even under concurrent callers — keep factories cheap and non-reentrant.
/// A `make` that throws caches nothing, so the next call for that key retries.
public final class SharedInstanceCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var instances: [String: Value] = [:]

    public init() {}

    /// Returns the cached instance for `key`, constructing and caching it via `make` if absent.
    public func instance(forKey key: String, make: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let existing = instances[key] {
            return existing
        }
        let made = try make()
        instances[key] = made
        return made
    }
}
