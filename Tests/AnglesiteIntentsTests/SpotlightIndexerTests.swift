import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    /// Verifies the diff/upsert behavior of `SpotlightIndexer` against a recording fake backend.
    /// The live `CSSearchableIndex` path isn't exercised here — it talks to the system index
    /// daemon, which has no usable test seam.
    @Suite("SpotlightIndexer")
    struct SpotlightIndexerTests {
        actor RecordingBackend: SpotlightIndexBackend {
            private(set) var indexedBatches: [[SiteEntity]] = []
            private(set) var deletedBatches: [[String]] = []

            func index(_ entities: [SiteEntity]) async throws {
                indexedBatches.append(entities)
            }
            func deleteEntities(identifiers: [String]) async throws {
                deletedBatches.append(identifiers)
            }
        }

        private func site(_ id: String, _ name: String) -> SiteStore.Site {
            SiteStore.Site(
                id: id,
                name: name,
                path: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true),
                isValid: true,
                missingSentinels: []
            )
        }

        @Test("first reindex publishes every site, deletes nothing")
        func firstReindexPublishesAllWithoutDeletes() async throws {
            let backend = RecordingBackend()
            let indexer = SpotlightIndexer(backend: backend)
            let outcome = try await indexer.reindex([site("s1", "Portfolio"), site("s2", "Blog")])

            #expect(outcome == .init(indexed: 2, removed: 0))
            let indexed = await backend.indexedBatches
            let deleted = await backend.deletedBatches
            #expect(indexed.count == 1)
            #expect(Set(indexed[0].map(\.id)) == Set(["s1", "s2"]))
            #expect(deleted.isEmpty)
        }

        @Test("subsequent reindex deletes ids dropped from the snapshot")
        func subsequentReindexDeletesDroppedIDs() async throws {
            let backend = RecordingBackend()
            let indexer = SpotlightIndexer(backend: backend)
            _ = try await indexer.reindex([site("s1", "Portfolio"), site("s2", "Blog")])
            let outcome = try await indexer.reindex([site("s1", "Portfolio")])

            #expect(outcome == .init(indexed: 1, removed: 1))
            let deleted = await backend.deletedBatches
            #expect(deleted.count == 1)
            #expect(deleted[0] == ["s2"])
        }

        @Test("reindex with empty snapshot deletes everything previously published")
        func reindexEmptyDeletesAll() async throws {
            let backend = RecordingBackend()
            let indexer = SpotlightIndexer(backend: backend)
            _ = try await indexer.reindex([site("s1", "Portfolio"), site("s2", "Blog")])
            let outcome = try await indexer.reindex([])

            #expect(outcome == .init(indexed: 0, removed: 2))
            let deleted = await backend.deletedBatches
            #expect(deleted.count == 1)
            #expect(Set(deleted[0]) == Set(["s1", "s2"]))
            // No index call for empty snapshot — avoids needless daemon traffic.
            let indexed = await backend.indexedBatches
            #expect(indexed.count == 1, "only the first non-empty reindex calls index()")
        }

        @Test("identical snapshot upserts again and deletes nothing")
        func identicalSnapshotUpsertsAgain() async throws {
            let backend = RecordingBackend()
            let indexer = SpotlightIndexer(backend: backend)
            _ = try await indexer.reindex([site("s1", "Portfolio")])
            let outcome = try await indexer.reindex([site("s1", "Portfolio")])

            // We don't dedupe-on-equality — the backend takes both upserts. Spotlight is
            // idempotent on (id, type), so cost is one daemon RPC. Cheaper than diffing
            // attribute sets here.
            #expect(outcome == .init(indexed: 1, removed: 0))
            let indexed = await backend.indexedBatches
            #expect(indexed.count == 2)
            let deleted = await backend.deletedBatches
            #expect(deleted.isEmpty)
        }
    }
}
