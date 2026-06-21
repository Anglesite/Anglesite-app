import AppIntents
import Foundation
import AnglesiteCore

/// Pluggable seam over the system `RelevantEntities` suggestion surface, so
/// `RelevantEntitiesUpdaterTests` can verify the top-N/dedup behavior without touching the
/// live App Intents relevance API. Mirrors `SpotlightIndexBackend`.
public protocol RelevantEntitiesBackend: Sendable {
    func update(_ entities: [SiteEntity]) async throws
}

/// Publishes the top-N most-recently-used sites to macOS 27's "relevant entities" suggestion
/// surface (distinct from the searchable index `SpotlightIndexer` maintains). Single entry
/// point: `refresh(_:)`, driven by `SiteStore.changeStream()` (see `AnglesiteIntents.bootstrap`).
///
/// `refresh` is diff-based on an **ordered** id list: it records the top-N ids published on the
/// last successful call and skips the backend when the new top-N ids match in the same order — so
/// a reorder of the lead sites re-publishes, while churn below the top-N (or an identical
/// snapshot) is a no-op. `lastPushedIDs` advances only on success, so a thrown backend error
/// replays on the next snapshot.
public actor RelevantEntitiesUpdater {
    public static let shared = RelevantEntitiesUpdater(backend: LiveRelevantEntitiesBackend())

    /// Result returned to callers (today: tests only) so they can assert the diff outcome.
    public struct Outcome: Sendable, Equatable {
        public let published: Int
        public let skipped: Bool

        public init(published: Int, skipped: Bool) {
            self.published = published
            self.skipped = skipped
        }
    }

    private let backend: any RelevantEntitiesBackend
    private let maxCount: Int
    private var lastPushedIDs: [String] = []

    public init(backend: any RelevantEntitiesBackend, maxCount: Int = 3) {
        self.backend = backend
        self.maxCount = maxCount
    }

    @discardableResult
    public func refresh(_ sites: [SiteStore.Site]) async throws -> Outcome {
        let top = Array(sites.prefix(maxCount))
        let ids = top.map(\.id)
        guard ids != lastPushedIDs else {
            return Outcome(published: top.count, skipped: true)
        }
        try await backend.update(top.map(SiteEntity.init))
        lastPushedIDs = ids
        return Outcome(published: top.count, skipped: false)
    }
}

/// Production backend — real `RelevantEntities` call wired in Task 2.
struct LiveRelevantEntitiesBackend: RelevantEntitiesBackend {
    func update(_ entities: [SiteEntity]) async throws {}
}
