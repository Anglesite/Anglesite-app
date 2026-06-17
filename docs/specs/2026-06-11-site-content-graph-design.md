# `SiteContentGraph` Actor — Design

**Status:** Design — approved
**Date:** 2026-06-11
**Issue:** [#136](https://github.com/Anglesite/Anglesite-app/issues/136) — A.1 `SiteContentGraph` actor + tests
**Parent epic:** [#132](https://github.com/Anglesite/Anglesite-app/issues/132) — Siri AI Phase A
**Parent design:** [`2026-06-11-siri-ai-integration-design.md`](./2026-06-11-siri-ai-integration-design.md) §Phase A

## Goal

Ship the foundation actor for Siri AI Phase A: an in-memory, push-driven projection of every open site's pages, posts, and images. The graph is what A.2 (`PageEntity`/`PostEntity`/`ImageEntity` queries), A.3 (`ContentSpotlightIndexer`), A.4 (`IntentEditBridge` headless lookups), and A.8 (`LocalSiteRuntime` → graph wiring) all sit on top of.

## Non-goals

- **No MCP wiring.** A.8 connects the firehose. A.1 ships the actor with no knowledge of MCP, plugins, or `LocalSiteRuntime`.
- **No `AppIntents` / `CoreSpotlight` imports.** Those land in A.2 / A.3 (in the `AnglesiteIntents` module). A.1 lives entirely in `AnglesiteCore`.
- **No persistence to disk.** The graph is a pure in-memory cache. Cold start = empty; A.8's `list_content` MCP call repopulates per site open. Filesystem stays the source of truth.
- **No derived cross-collection state.** `Image.usedOnPages` is plugin-supplied and stored verbatim — the graph does not maintain a page-→-image reverse index.

## Architecture

### Module placement

- **File:** `Sources/AnglesiteCore/SiteContentGraph.swift` (new, single file, single actor — mirrors `SiteStore.swift`'s shape).
- **Module:** `AnglesiteCore` only. No new framework imports.
- **Ownership:** No `static let shared`. A single instance is held by app lifecycle (passed by `AnglesiteApp` into `AnglesiteIntents.bootstrap()` and `LocalSiteRuntime` in A.8). Tests construct fresh instances. This matches the dependency-injection seam established by `SiteOperationsOverride.scoped` and avoids singleton-induced flakiness in concurrent test runs.

### Consumer relationship

The graph is push-driven with a single change-handler subscriber (A.3's `ContentSpotlightIndexer`). The handler signature is **siteID-only**; the subscriber calls back into the graph for the current snapshot of pages/posts/images for that siteID. Rationale: matches `SpotlightIndexer.reindex(_:)`'s existing diff-based pattern (it trusts whatever the source publishes at the moment of read), keeps emit cheap, and avoids shipping a per-mutation snapshot that not all future consumers will need.

If a second subscriber appears later, we'll fan out then. Single-subscriber is a deliberate match with `SiteStore.ChangeHandler`, which has shipped against the same single-consumer reality.

## Public API

```swift
public actor SiteContentGraph {
    public struct Page: Sendable, Equatable, Identifiable {
        public let id: String          // "{siteID}:page:{route}"
        public let siteID: String
        public let route: String
        public let filePath: String
        public let title: String?
        public let lastModified: Date
    }

    public struct Post: Sendable, Equatable, Identifiable {
        public let id: String          // "{siteID}:post:{slug}"
        public let siteID: String
        public let collection: String
        public let slug: String
        public let title: String
        public let draft: Bool
        public let publishDate: Date?
        public let tags: [String]
        public let filePath: String
        public let lastModified: Date
    }

    public struct Image: Sendable, Equatable, Identifiable {
        public let id: String          // "{siteID}:image:{relativePath}"
        public let siteID: String
        public let relativePath: String
        public let fileName: String
        public let byteSize: Int64?
        public let usedOnPages: [String]  // plugin-supplied, opaque to graph
        public let lastModified: Date
    }

    public typealias ChangeHandler = @Sendable (String) async -> Void

    public init()

    public func setChangeHandler(_ handler: ChangeHandler?)

    // Bulk — replaces all entries for siteID
    public func load(siteID: String,
                     pages: [Page],
                     posts: [Post],
                     images: [Image]) async

    // Incremental — emit suppressed on Equatable no-op
    public func upsertPage(_ page: Page) async
    public func upsertPost(_ post: Post) async
    public func upsertImage(_ image: Image) async
    public func removePage(id: String) async
    public func removePost(id: String) async
    public func removeImage(id: String) async

    // Queries
    public func pages(for siteID: String) -> [Page]
    public func posts(for siteID: String) -> [Post]
    public func images(for siteID: String) -> [Image]
    public func page(id: String) -> Page?
    public func post(id: String) -> Post?
    public func image(id: String) -> Image?

    // Search — case-insensitive substring
    public func searchPages(siteID: String, matching query: String) -> [Page]
    public func searchPosts(siteID: String, matching query: String) -> [Post]

    // Teardown
    public func unload(siteID: String) async

    // Bonus for A.3 — enumerate populated sites
    public func knownSiteIDs() -> Set<String>
}
```

### Deltas from the parent design spec

- **Mutating methods are `async`** so they can `await emitChange()`. Queries and `setChangeHandler` stay synchronous (no I/O).
- **`knownSiteIDs()` added** for A.3's "this whole site went away" diff case. Cheap to compute, no other consumers yet.

All struct shapes preserved exactly from the parent spec.

## Data flow

### Population (A.8 wires this; A.1 just exposes the seam)

```
LocalSiteRuntime starts
  └─ MCP client calls list_content (plugin paired PR, A.6)
       └─ graph.load(siteID: siteID, pages, posts, images)
            ├─ drops existing entries with siteID
            ├─ installs new entries
            └─ emitChange(siteID)
                 └─ ContentSpotlightIndexer (A.3) reads back:
                      pages  = await graph.pages(for: siteID)
                      posts  = await graph.posts(for: siteID)
                      images = await graph.images(for: siteID)
                      try await indexer.reindex(...)
```

### Incremental (MCP file-watch events)

```
graph.upsertPage(updatedPage)
  ├─ if pages[id] == updatedPage { return }     ← no-op suppression
  ├─ pages[id] = updatedPage
  └─ emitChange(updatedPage.siteID)
```

### Teardown (site window closed)

```
graph.unload(siteID: siteID)
  ├─ pages  = pages.filter  { $0.value.siteID != siteID }
  ├─ posts  = posts.filter  { $0.value.siteID != siteID }
  ├─ images = images.filter { $0.value.siteID != siteID }
  └─ emitChange(siteID)        ← tells indexer "site is empty now"
```

## Invariants

1. **siteID isolation.** A mutation for siteID `A` never affects entries with siteID `B`.
2. **Bulk-load replaces.** A second `load(siteID: X, ...)` evicts everything from the first `load(siteID: X, ...)` not present in the second's payload.
3. **No-op suppression.** `upsert*` with an `Equatable`-equal existing entry does not emit. (`lastModified: Date` is part of the equality check, so an mtime-only file-watch event WILL count as a real change and fire — intentional; saves are coarse enough that this is cheap.)
4. **Unknown-id remove is silent.** `removePage(id:)` on an unknown id does nothing and does not emit.
5. **`unload` always emits.** Even if the site had no entries, the handler fires so a subscriber can confirm "site is empty now" and prune any stale tracking.
6. **Single subscriber.** `setChangeHandler` replaces the current handler. Passing `nil` detaches.
7. **Actor-serialized emit.** `emitChange` runs on the actor's executor (same as `SiteStore.emitChange`). Consumers see a consistent snapshot when they read back from the graph inside the handler.
8. **Empty-query convention.** `searchPages` / `searchPosts` with `query == ""` returns all entries for that siteID (no filtering).

## Tests

`Tests/AnglesiteCoreTests/SiteContentGraphTests.swift` — Swift Testing, ~16 `@Test` cases.

| # | Test | Invariant covered |
|---|---|---|
| 1 | `loadReplacesExistingEntries` | Inv 2 |
| 2 | `loadDoesNotAffectOtherSites` | Inv 1 |
| 3 | `upsertPageEmitsChange` | emit policy |
| 4 | `upsertPageWithIdenticalValueSuppressesEmit` | Inv 3 |
| 5 | `upsertPostSuppressesEmitOnIdentical` | Inv 3 |
| 6 | `upsertImageSuppressesEmitOnIdentical` | Inv 3 |
| 7 | `removePageEmitsChange` | emit policy |
| 8 | `removePageNoopWhenIDUnknown` | Inv 4 |
| 9 | `unloadDropsAllEntriesForSite` | teardown semantics |
| 10 | `unloadEmitsChange` | Inv 5 |
| 11 | `searchPagesMatchesTitleAndRouteCaseInsensitive` | search semantics |
| 12 | `searchPostsMatchesTitleSlugTagsCollection` | search semantics |
| 13 | `searchWithEmptyQueryReturnsAll` | Inv 8 |
| 14 | `knownSiteIDsReflectsCurrentContent` | enumeration |
| 15 | `setChangeHandlerNilRemovesHandler` | Inv 6 |
| 16 | `concurrentUpsertsAreSerialized` | Inv 7 (N parallel upserts, assert final count == N) |

The graph has no I/O surface, so no `Backend` protocol is needed (contrast `SpotlightIndexer` which has `SpotlightIndexBackend` for the `CSSearchableIndex` seam). Tests construct `SiteContentGraph()` directly and assert via the public query surface.

## Scope boundaries (what A.1 does NOT do)

- **No MCP / plugin wiring.** A.8 (#142).
- **No `IndexedEntity` conformance.** A.2 (#137).
- **No `ContentSpotlightIndexer`.** A.3 (#144).
- **No `list_content` MCP tool.** Plugin paired PR (#140 / A.6).
- **No persistence to disk.** Permanently in-memory by design.

## Acceptance criteria

- [ ] `Sources/AnglesiteCore/SiteContentGraph.swift` exists with the public API above.
- [ ] `Tests/AnglesiteCoreTests/SiteContentGraphTests.swift` exists with all 16 tests.
- [ ] `swift test --package-path .` passes (no regressions to the existing 270-test suite).
- [ ] Both Xcode schemes (`Anglesite`, `AnglesiteMAS`) still build clean with the new file.
- [ ] No new dependencies (Foundation only; no AppIntents, CoreSpotlight, or third-party).

## Open follow-ups (deferred)

None for A.1. The next dependent issues (A.2 #137, A.3 #144, A.8 #142) start work after this lands and the bundled-plugin pointer is bumped to include `list_content`.
