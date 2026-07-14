import Foundation
import AnglesiteCore
import Containerization

/// Process-wide `ImageStore` per store directory (#573).
///
/// `ImageStore` serializes its multi-step operations — `load(from:)`'s move-blobs-then-write-
/// reference window, `cleanUpOrphanedBlobs()`'s list-then-delete sweep — with an `AsyncLock`
/// stored on the *instance*. That serialization only protects callers who share the instance:
/// constructing a fresh `ImageStore(path:)` per boot (the pre-#573 behavior) gave each site
/// window its own lock over the same on-disk store, so one window's cleanup could delete blobs
/// another window's in-flight import had ingested but not yet referenced. Every store access goes
/// through here so all windows resolve the same instance — upstream models the same requirement
/// with its own process-wide `ImageStore.default`. The sharing semantics (one instance per key,
/// even under concurrent callers) are CI-covered via `SharedInstanceCache` in AnglesiteCore.
///
/// Confirmed against the vendored source (apple/containerization @ `44bec8b9`, package
/// version 0.35.0, pinned in `Package.resolved`):
/// - `ImageStore.load(from:)` (`ImageStore+OCILayout.swift:92-100`) moves ingested blobs into the
///   content store (`completeIngestSession`) and writes each image's reference (`_create`) inside
///   one `self.lock.withLock { ... }` call — both steps are the same critical section, not two.
/// - `ImageStore.cleanUpOrphanedBlobs()` (`ImageStore.swift:138-142`) takes the identical
///   `self.lock.withLock`.
/// - `AsyncLock.withLock` (`AsyncLock.swift:37-60`) is a true mutex: a `busy` flag plus a FIFO
///   continuation queue, set before `body` runs and cleared only in `body`'s `defer` — so a second
///   `withLock` call on the same instance genuinely suspends until the first's `body` (the whole
///   ingest-complete-then-create step, or the whole cleanup sweep) has returned. No reentrancy, no
///   partial release.
///
/// Together this means: on one shared instance, `cleanUpOrphanedBlobs()` can never observe a state
/// where blobs are ingested but not yet referenced — that window only exists *inside* the other
/// `withLock` call, which cleanup cannot enter until it exits.
enum SharedImageStore {
    private static let cache = SharedInstanceCache<ImageStore>()

    /// Returns the process-wide `ImageStore` for the store directory at `url`.
    static func store(at url: URL) throws -> ImageStore {
        try cache.instance(forKey: url.standardizedFileURL.path) { try ImageStore(path: url) }
    }
}
