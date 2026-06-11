import AppIntents
import CoreSpotlight
import Foundation
import AnglesiteCore

/// Conforming `SiteEntity` to `IndexedEntity` is what lets `CSSearchableIndex.indexAppEntities`
/// accept it and contribute to macOS 27's Spotlight semantic index. The default `attributeSet`
/// synthesized from the entity's `displayRepresentation` (title + subtitle) is sufficient for v0
/// — override only if Spotlight result formatting needs more (kind, contentURL, thumbnail).
extension SiteEntity: IndexedEntity {}

/// Pluggable seam over `CSSearchableIndex` so `SpotlightIndexerTests` can verify the diff/upsert
/// sequencing without hitting the live system index daemon.
public protocol SpotlightIndexBackend: Sendable {
    func index(_ entities: [SiteEntity]) async throws
    func deleteEntities(identifiers: [String]) async throws
}

/// Maintains the Spotlight semantic index for `SiteEntity`. Single-entry point: `reindex(_:)`.
///
/// `reindex` is diff-based — it tracks the id set published on the last call and deletes any
/// id absent from the new snapshot before upserting the current set. This mirrors the
/// "fold a stream of `SiteStore` mutations into the index" use case driven by
/// `SiteStore.setChangeHandler` (see `AnglesiteIntents.bootstrap`).
public actor SpotlightIndexer {
    public static let shared = SpotlightIndexer(backend: LiveSpotlightBackend())

    private let backend: any SpotlightIndexBackend
    private var lastIndexedIDs: Set<String> = []

    public init(backend: any SpotlightIndexBackend) {
        self.backend = backend
    }

    /// Result returned to callers (today: tests only) so they can assert the diff outcome.
    public struct Outcome: Sendable, Equatable {
        public let indexed: Int
        public let removed: Int
    }

    /// Compute the diff against the previously-indexed set, delete anything dropped, then
    /// upsert the current set. Resets the tracked set even if the backend throws on upsert —
    /// the caller can retry; we don't want to wedge into "everything looks deleted" state.
    @discardableResult
    public func reindex(_ sites: [SiteStore.Site]) async throws -> Outcome {
        let entities = sites.map(SiteEntity.init)
        let currentIDs = Set(entities.map(\.id))
        let removedIDs = lastIndexedIDs.subtracting(currentIDs)

        if !removedIDs.isEmpty {
            try await backend.deleteEntities(identifiers: Array(removedIDs))
        }
        if !entities.isEmpty {
            try await backend.index(entities)
        }
        lastIndexedIDs = currentIDs
        return Outcome(indexed: entities.count, removed: removedIDs.count)
    }
}

/// Production backend. Routes to `CSSearchableIndex.default()`, the system-wide index used by
/// Spotlight and Siri. macOS 27 routes `IndexedEntity` writes through the semantic index.
struct LiveSpotlightBackend: SpotlightIndexBackend {
    func index(_ entities: [SiteEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    func deleteEntities(identifiers: [String]) async throws {
        try await CSSearchableIndex.default().deleteAppEntities(
            identifiedBy: identifiers,
            ofType: SiteEntity.self
        )
    }
}
