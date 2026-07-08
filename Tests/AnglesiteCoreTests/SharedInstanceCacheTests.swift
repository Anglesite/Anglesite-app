import Testing
import Foundation
@testable import AnglesiteCore

/// Unit tests for the process-wide keyed instance cache backing `SharedImageStore` in
/// AnglesiteContainer (CI never compiles that module, so the sharing semantics are proven here).
/// The cache exists because `ImageStore`'s `AsyncLock` is per-instance: two instances over the
/// same store directory hold two locks, so a `cleanUpOrphanedBlobs()` through one can delete
/// blobs a `load(from:)` through the other has ingested but not yet referenced (#573). Sharing
/// one instance per key restores "one lock per store directory".
struct SharedInstanceCacheTests {
    private final class Token: Sendable {}

    @Test("the same key returns the identical instance, constructing it only once")
    func sameKeyReturnsSameInstance() throws {
        let cache = SharedInstanceCache<Token>()
        var factoryCalls = 0

        let first = cache.instance(forKey: "store-a") { factoryCalls += 1; return Token() }
        let second = cache.instance(forKey: "store-a") { factoryCalls += 1; return Token() }

        #expect(first === second)
        #expect(factoryCalls == 1)
    }

    @Test("distinct keys get distinct instances")
    func distinctKeysGetDistinctInstances() throws {
        let cache = SharedInstanceCache<Token>()

        let a = cache.instance(forKey: "store-a") { Token() }
        let b = cache.instance(forKey: "store-b") { Token() }

        #expect(a !== b)
    }

    @Test("a throwing factory propagates its error and caches nothing, so a later call can succeed")
    func factoryErrorIsNotCached() throws {
        struct MakeFailed: Error {}
        let cache = SharedInstanceCache<Token>()

        #expect(throws: MakeFailed.self) {
            try cache.instance(forKey: "store-a") { throw MakeFailed() }
        }

        // The failure must not poison the key: the next attempt constructs and caches normally.
        let recovered = cache.instance(forKey: "store-a") { Token() }
        let again = cache.instance(forKey: "store-a") { Token() }
        #expect(recovered === again)
    }

    @Test("concurrent callers for one key all receive the identical instance (factory runs once)")
    func concurrentCallersShareOneInstance() async throws {
        let cache = SharedInstanceCache<Token>()
        let factoryCalls = Atomic(0)

        let instances = await withTaskGroup(of: Token.self, returning: [Token].self) { group in
            for _ in 0..<64 {
                group.addTask {
                    cache.instance(forKey: "store-a") {
                        factoryCalls.increment()
                        return Token()
                    }
                }
            }
            var results: [Token] = []
            for await token in group { results.append(token) }
            return results
        }

        #expect(factoryCalls.value == 1)
        let canonical = try #require(instances.first)
        #expect(instances.allSatisfy { $0 === canonical })
    }
}

/// Minimal lock-guarded counter for asserting factory-call counts from concurrent tasks.
private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int
    init(_ value: Int) { count = value }
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
