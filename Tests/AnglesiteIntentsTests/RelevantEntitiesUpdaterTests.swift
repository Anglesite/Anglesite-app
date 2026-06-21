import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    /// Verifies the top-N truncation and order-sensitive dedup of `RelevantEntitiesUpdater`
    /// against a recording fake backend. The live `RelevantEntities` system surface isn't
    /// exercised here — it has no usable test seam (mirrors `SpotlightIndexerTests`).
    @Suite("RelevantEntitiesUpdater")
    struct RelevantEntitiesUpdaterTests {
        actor RecordingBackend: RelevantEntitiesBackend {
            private(set) var updatedBatches: [[SiteEntity]] = []
            func update(_ entities: [SiteEntity]) async throws {
                updatedBatches.append(entities)
            }
        }

        private func site(_ id: String, _ name: String) -> SiteStore.Site {
            SiteStore.Site(
                id: id,
                name: name,
                packageURL: URL(fileURLWithPath: "/tmp/\(name).anglesite", isDirectory: true),
                isValid: true,
                missingSentinels: []
            )
        }

        @Test("first refresh publishes the top-N in MRU order, dropping the rest")
        func firstRefreshPublishesTopN() async throws {
            let backend = RecordingBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)
            let outcome = try await updater.refresh([
                site("a", "A"), site("b", "B"), site("c", "C"), site("d", "D"),
            ])

            #expect(outcome == .init(published: 3, skipped: false))
            let batches = await backend.updatedBatches
            #expect(batches.count == 1)
            #expect(batches[0].map(\.id) == ["a", "b", "c"])
        }

        @Test("an unchanged top-N id list skips the backend call")
        func unchangedTopNSkips() async throws {
            let backend = RecordingBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)
            _ = try await updater.refresh([site("a", "A"), site("b", "B"), site("c", "C")])
            let outcome = try await updater.refresh([site("a", "A"), site("b", "B"), site("c", "C")])

            #expect(outcome == .init(published: 3, skipped: true))
            let batches = await backend.updatedBatches
            #expect(batches.count == 1) // second refresh did not call the backend
        }

        @Test("a reorder of the lead sites re-publishes")
        func reorderOfLeadRepublishes() async throws {
            let backend = RecordingBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)
            _ = try await updater.refresh([site("a", "A"), site("b", "B"), site("c", "C")])
            let outcome = try await updater.refresh([site("b", "B"), site("a", "A"), site("c", "C")])

            #expect(outcome == .init(published: 3, skipped: false))
            let batches = await backend.updatedBatches
            #expect(batches.count == 2)
            #expect(batches[1].map(\.id) == ["b", "a", "c"])
        }

        @Test("a reorder below the top-N is skipped")
        func reorderBelowTopNSkips() async throws {
            let backend = RecordingBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)
            _ = try await updater.refresh([site("a", "A"), site("b", "B"), site("c", "C"), site("d", "D")])
            // d and e swap below the top-3 — top-3 id list (a,b,c) is unchanged.
            let outcome = try await updater.refresh([site("a", "A"), site("b", "B"), site("c", "C"), site("e", "E")])

            #expect(outcome == .init(published: 3, skipped: true))
            let batches = await backend.updatedBatches
            #expect(batches.count == 1)
        }

        @Test("an empty snapshot clears once, then dedups")
        func emptyClearsOnceThenDedups() async throws {
            let backend = RecordingBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)
            _ = try await updater.refresh([site("a", "A")])
            let cleared = try await updater.refresh([])
            let again = try await updater.refresh([])

            #expect(cleared == .init(published: 0, skipped: false))
            #expect(again == .init(published: 0, skipped: true))
            let batches = await backend.updatedBatches
            #expect(batches.count == 2)          // initial push + one clear
            #expect(batches[1].isEmpty)
        }

        @Test("a backend throw leaves lastPushedIDs unchanged so the next refresh retries")
        func backendThrowRetries() async throws {
            actor ThrowOnceBackend: RelevantEntitiesBackend {
                private var calls = 0
                private(set) var succeededBatches: [[SiteEntity]] = []
                func update(_ entities: [SiteEntity]) async throws {
                    calls += 1
                    if calls == 1 { throw CancellationError() }
                    succeededBatches.append(entities)
                }
            }
            let backend = ThrowOnceBackend()
            let updater = RelevantEntitiesUpdater(backend: backend, maxCount: 3)

            await #expect(throws: CancellationError.self) {
                _ = try await updater.refresh([site("a", "A"), site("b", "B")])
            }
            // Same snapshot: because the first push threw, the id list was not recorded,
            // so this is NOT deduped — it retries and succeeds.
            let outcome = try await updater.refresh([site("a", "A"), site("b", "B")])
            #expect(outcome == .init(published: 2, skipped: false))
            let batches = await backend.succeededBatches
            #expect(batches.count == 1)
            #expect(batches[0].map(\.id) == ["a", "b"])
        }
    }
}
