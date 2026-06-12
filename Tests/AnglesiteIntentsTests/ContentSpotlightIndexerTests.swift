import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Verifies the per-site, per-type diff/upsert behavior of `ContentSpotlightIndexer` (A.3, #144)
/// against a recording fake backend. The live `CSSearchableIndex` path isn't exercised — it talks
/// to the system index daemon, which has no usable test seam. Reuses the `gPage/gPost/gImage`
/// fixtures from `ContentEntitiesTests`.
extension AppIntentsTests {
    @Suite("ContentSpotlightIndexer")
    struct ContentSpotlightIndexerTests {
        actor RecordingBackend: ContentSpotlightBackend {
            private(set) var indexedPages: [[PageEntity]] = []
            private(set) var indexedPosts: [[PostEntity]] = []
            private(set) var indexedImages: [[ImageEntity]] = []
            private(set) var deletedPages: [[String]] = []
            private(set) var deletedPosts: [[String]] = []
            private(set) var deletedImages: [[String]] = []

            func indexPages(_ entities: [PageEntity]) async throws { indexedPages.append(entities) }
            func indexPosts(_ entities: [PostEntity]) async throws { indexedPosts.append(entities) }
            func indexImages(_ entities: [ImageEntity]) async throws { indexedImages.append(entities) }
            func deletePages(identifiers: [String]) async throws { deletedPages.append(identifiers) }
            func deletePosts(identifiers: [String]) async throws { deletedPosts.append(identifiers) }
            func deleteImages(identifiers: [String]) async throws { deletedImages.append(identifiers) }
        }

        private func makeGraph() -> SiteContentGraph { SiteContentGraph() }

        @Test("first reindex publishes all three types and deletes nothing")
        func firstReindexPublishesAll() async throws {
            let graph = makeGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage(route: "/about"), AppIntentsTests.gPage(route: "/contact")],
                posts: [AppIntentsTests.gPost(slug: "hello")],
                images: [AppIntentsTests.gImage()]
            )
            let backend = RecordingBackend()
            let indexer = ContentSpotlightIndexer(graph: graph, backend: backend)

            let outcome = try await indexer.reindex(siteID: AppIntentsTests.aSite)

            #expect(outcome == .init(indexed: 4, removed: 0))
            #expect(await Set(backend.indexedPages.first?.map(\.route) ?? []) == ["/about", "/contact"])
            #expect(await backend.indexedPosts.first?.map(\.slug) == ["hello"])
            #expect(await backend.indexedImages.first?.map(\.id) == [AppIntentsTests.gImage().id])
            #expect(await backend.deletedPages.isEmpty)
            #expect(await backend.deletedPosts.isEmpty)
            #expect(await backend.deletedImages.isEmpty)
        }

        @Test("empty content types are not sent to index()")
        func emptyTypesSkipIndex() async throws {
            let graph = makeGraph()
            await graph.load(siteID: AppIntentsTests.aSite, pages: [AppIntentsTests.gPage()], posts: [], images: [])
            let backend = RecordingBackend()
            let indexer = ContentSpotlightIndexer(graph: graph, backend: backend)

            let outcome = try await indexer.reindex(siteID: AppIntentsTests.aSite)

            #expect(outcome == .init(indexed: 1, removed: 0))
            #expect(await backend.indexedPages.count == 1)
            #expect(await backend.indexedPosts.isEmpty)
            #expect(await backend.indexedImages.isEmpty)
        }

        @Test("dropping a page deletes just that id and re-upserts the rest")
        func dropsOnePage() async throws {
            let graph = makeGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage(route: "/about"), AppIntentsTests.gPage(route: "/contact")],
                posts: [], images: []
            )
            let backend = RecordingBackend()
            let indexer = ContentSpotlightIndexer(graph: graph, backend: backend)
            _ = try await indexer.reindex(siteID: AppIntentsTests.aSite)

            await graph.removePage(id: AppIntentsTests.gPage(route: "/contact").id)
            let outcome = try await indexer.reindex(siteID: AppIntentsTests.aSite)

            #expect(outcome == .init(indexed: 1, removed: 1))
            #expect(await backend.deletedPages == [[AppIntentsTests.gPage(route: "/contact").id]])
            #expect(await backend.indexedPages.last?.map(\.route) == ["/about"])
        }

        @Test("unloading a site deletes everything previously published for it")
        func unloadDeletesAll() async throws {
            let graph = makeGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage()],
                posts: [AppIntentsTests.gPost()],
                images: [AppIntentsTests.gImage()]
            )
            let backend = RecordingBackend()
            let indexer = ContentSpotlightIndexer(graph: graph, backend: backend)
            _ = try await indexer.reindex(siteID: AppIntentsTests.aSite)

            await graph.unload(siteID: AppIntentsTests.aSite)
            let outcome = try await indexer.reindex(siteID: AppIntentsTests.aSite)

            #expect(outcome == .init(indexed: 0, removed: 3))
            #expect(await backend.deletedPages == [[AppIntentsTests.gPage().id]])
            #expect(await backend.deletedPosts == [[AppIntentsTests.gPost().id]])
            #expect(await backend.deletedImages == [[AppIntentsTests.gImage().id]])
        }

        @Test("reindexing a second site never deletes the first site's entities")
        func perSiteScoping() async throws {
            let graph = makeGraph()
            await graph.load(siteID: AppIntentsTests.aSite, pages: [AppIntentsTests.gPage(site: AppIntentsTests.aSite, route: "/about")], posts: [], images: [])
            await graph.load(siteID: AppIntentsTests.bSite, pages: [AppIntentsTests.gPage(site: AppIntentsTests.bSite, route: "/contact")], posts: [], images: [])
            let backend = RecordingBackend()
            let indexer = ContentSpotlightIndexer(graph: graph, backend: backend)

            _ = try await indexer.reindex(siteID: AppIntentsTests.aSite)
            let outcome = try await indexer.reindex(siteID: AppIntentsTests.bSite)

            // B's first reindex must not delete A's previously-indexed page.
            #expect(outcome == .init(indexed: 1, removed: 0))
            #expect(await backend.deletedPages.isEmpty)
            #expect(await backend.indexedPages.map { $0.map(\.route) } == [["/about"], ["/contact"]])
        }

        @Test("identical snapshot upserts again and deletes nothing")
        func identicalSnapshotReupserts() async throws {
            let graph = makeGraph()
            await graph.load(siteID: AppIntentsTests.aSite, pages: [AppIntentsTests.gPage()], posts: [], images: [])
            let backend = RecordingBackend()
            let indexer = ContentSpotlightIndexer(graph: graph, backend: backend)
            _ = try await indexer.reindex(siteID: AppIntentsTests.aSite)
            let outcome = try await indexer.reindex(siteID: AppIntentsTests.aSite)

            #expect(outcome == .init(indexed: 1, removed: 0))
            #expect(await backend.indexedPages.count == 2)
            #expect(await backend.deletedPages.isEmpty)
        }

        @Test("dropping one post type leaves pages re-upserted and deletes only the post")
        func mixedTypeDiff() async throws {
            let graph = makeGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage()],
                posts: [AppIntentsTests.gPost(slug: "hello")],
                images: []
            )
            let backend = RecordingBackend()
            let indexer = ContentSpotlightIndexer(graph: graph, backend: backend)
            _ = try await indexer.reindex(siteID: AppIntentsTests.aSite)

            await graph.removePost(id: AppIntentsTests.gPost(slug: "hello").id)
            let outcome = try await indexer.reindex(siteID: AppIntentsTests.aSite)

            #expect(outcome == .init(indexed: 1, removed: 1))
            #expect(await backend.deletedPosts == [[AppIntentsTests.gPost(slug: "hello").id]])
            #expect(await backend.deletedPages.isEmpty)
            #expect(await backend.indexedPages.last?.map(\.id) == [AppIntentsTests.gPage().id])
        }

        /// Backend that, on its first `indexPages`, mutates the graph and fires a *reentrant*
        /// `reindex` for the same site — reproducing the interleaving the change handler causes
        /// when a graph mutation lands while a pass is mid-flight. With per-site coalescing the
        /// second call defers and the leader re-runs, so the new page ends up tracked; without
        /// it, the leader's stale write clobbers the new page and it leaks in the index.
        actor ReentrantBackend: ContentSpotlightBackend {
            private(set) var indexedPages: [[PageEntity]] = []
            private(set) var deletedPages: [[String]] = []
            var indexer: ContentSpotlightIndexer?
            var graph: SiteContentGraph?
            var onFirstIndex: (@Sendable () async -> Void)?

            func indexPages(_ entities: [PageEntity]) async throws {
                indexedPages.append(entities)
                if let hook = onFirstIndex {
                    onFirstIndex = nil
                    await hook()
                }
            }
            func indexPosts(_ entities: [PostEntity]) async throws {}
            func indexImages(_ entities: [ImageEntity]) async throws {}
            func deletePages(identifiers: [String]) async throws { deletedPages.append(identifiers) }
            func deletePosts(identifiers: [String]) async throws {}
            func deleteImages(identifiers: [String]) async throws {}

            func configure(indexer: ContentSpotlightIndexer, graph: SiteContentGraph, onFirstIndex: @escaping @Sendable () async -> Void) {
                self.indexer = indexer
                self.graph = graph
                self.onFirstIndex = onFirstIndex
            }
        }

        @Test("a reentrant reindex mid-pass does not lose the newly-added page")
        func reentrantReindexDoesNotLoseUpdate() async throws {
            let graph = makeGraph()
            let site = AppIntentsTests.aSite
            await graph.load(siteID: site, pages: [AppIntentsTests.gPage(route: "/about")], posts: [], images: [])

            let backend = ReentrantBackend()
            let indexer = ContentSpotlightIndexer(graph: graph, backend: backend)
            // While the first indexPages([/about]) is awaiting, add /contact and fire a second
            // reindex for the same site — exactly the change-handler reentrancy under load.
            await backend.configure(indexer: indexer, graph: graph) {
                await graph.upsertPage(AppIntentsTests.gPage(route: "/contact"))
                _ = try? await indexer.reindex(siteID: site)
            }

            _ = try await indexer.reindex(siteID: site)

            // The leader must have folded in /contact (coalesced re-run), so it's tracked. Proof:
            // removing it now produces a delete. If it had leaked, the diff would never delete it.
            await graph.removePage(id: AppIntentsTests.gPage(route: "/contact").id)
            _ = try await indexer.reindex(siteID: site)
            #expect(await backend.deletedPages == [[AppIntentsTests.gPage(route: "/contact").id]])
        }

        @Test("re-adding a previously-removed site re-publishes it")
        func reAddAfterUnload() async throws {
            let graph = makeGraph()
            await graph.load(siteID: AppIntentsTests.aSite, pages: [AppIntentsTests.gPage()], posts: [], images: [])
            let backend = RecordingBackend()
            let indexer = ContentSpotlightIndexer(graph: graph, backend: backend)
            _ = try await indexer.reindex(siteID: AppIntentsTests.aSite)
            await graph.unload(siteID: AppIntentsTests.aSite)
            _ = try await indexer.reindex(siteID: AppIntentsTests.aSite)

            await graph.load(siteID: AppIntentsTests.aSite, pages: [AppIntentsTests.gPage()], posts: [], images: [])
            let outcome = try await indexer.reindex(siteID: AppIntentsTests.aSite)

            #expect(outcome == .init(indexed: 1, removed: 0))
            #expect(await backend.indexedPages.last?.map(\.id) == [AppIntentsTests.gPage().id])
        }
    }
}
