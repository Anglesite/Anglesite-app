# `PageEntity` / `PostEntity` / `ImageEntity` — Design

**Status:** Design — approved
**Date:** 2026-06-11
**Issue:** [#137](https://github.com/Anglesite/Anglesite-app/issues/137) — A.2 `PageEntity`, `PostEntity`, `ImageEntity` + queries + tests
**Parent epic:** [#132](https://github.com/Anglesite/Anglesite-app/issues/132) — Siri AI Phase A
**Parent design:** [`2026-06-11-siri-ai-integration-design.md`](./2026-06-11-siri-ai-integration-design.md) §Phase A.2
**Depends on:** [#136 (A.1) `SiteContentGraph`](./2026-06-11-site-content-graph-design.md) — shipped on `main` as `aa72ab4`

## Goal

Add three `AppEntity` types — `PageEntity`, `PostEntity`, `ImageEntity` — and their `EntityStringQuery` companions. These are thin projections over `SiteContentGraph` that let Siri, Shortcuts, and Spotlight (A.3) reference sub-site content.

## Non-goals

- **No `ContentSpotlightIndexer`.** A.3 (#144) consumes these entities through Spotlight; A.2 ships the entities only.
- **No new intents.** A.5 (#139) introduces `EditContentIntent` / `SearchContentIntent` / etc. that use these entities.
- **No icons / image thumbnails / page favicons** in `displayRepresentation`. Title + subtitle only. Visual polish is a follow-up after Siri-resolution behavior is validated.
- **No `usedOnPages` on `ImageEntity`.** The field exists in `SiteContentGraph.Image` but is not surfaced to the entity layer in v0 — no consumer needs it yet.
- **No MRU site tracking.** The parent spec's "pages for MRU site" wording is dropped — `suggestedEntities()` returns all entries across all known sites, sorted by `lastModified` DESC. No new state is added to `SiteStore` or `SiteWindow`.
- **No auto-pick `defaultResult`** for any of the three. Multi-page sites would make that surprising.

## Architecture

### Module placement

- **`Sources/AnglesiteIntents/ContentEntities.swift`** (new) — three entity structs + three query structs. Single file per the issue body. Estimated ~300 lines.
- **`Sources/AnglesiteIntents/ContentGraphOverride.swift`** (new) — `@TaskLocal` test escape hatch. ~15 lines, mirrors `SiteOperationsOverride.swift`.
- **`Sources/AnglesiteIntents/Bootstrap.swift`** (modified) — `AnglesiteIntents.bootstrap` gains a `contentGraph:` parameter to register the graph with `AppDependencyManager`.

Imports: `AppIntents`, `AnglesiteCore`, `Foundation`. No new dependencies.

### Graph injection

`@Dependency` + bootstrap registration — matches the existing intent pattern (`SiteIntents.swift:22`). The app constructs a single `SiteContentGraph()` instance at launch, passes it into `bootstrap(contentGraph:)`, and the dependency manager hands it out to any query that declares `@Dependency private var graph: SiteContentGraph`.

Tests bypass `@Dependency` (which is gated by the AppIntents runtime to its perform flow) via `ContentGraphOverride.$scoped.withValue(graph)`. Queries resolve `ContentGraphOverride.scoped ?? graph` so the override takes precedence when set.

This preserves [A.1's "no `static let shared`" decision](./2026-06-11-site-content-graph-design.md#module-placement) — app-lifecycle ownership of the graph stays explicit, tests stay isolation-clean.

### Bootstrap signature change

```swift
// Before
public static func bootstrap() async

// After (this PR)
public static func bootstrap(contentGraph: SiteContentGraph) async
```

`AnglesiteApp` callsites (DevID + MAS scene roots) are updated in the same PR — this is the breaking-API moment for A.2. Both schemes must build.

## Public API

### `PageEntity`

```swift
public struct PageEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String            // "{siteID}:page:{route}" — same as SiteContentGraph.Page.id
    public let displayName: String   // title ?? route
    public let route: String
    public let siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Page" }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(route)")
    }
    public static var defaultQuery = PageEntityQuery()

    public init(_ page: SiteContentGraph.Page) {
        self.id = page.id
        self.displayName = page.title ?? page.route
        self.route = page.route
        self.siteID = page.siteID
    }
}
```

### `PostEntity`

```swift
public struct PostEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String            // "{siteID}:post:{slug}"
    public let displayName: String   // title
    public let slug: String
    public let collection: String
    public let siteID: String
    public let isDraft: Bool
    public let tags: [String]

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Post" }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(collection)/\(slug)\(isDraft ? " (draft)" : "")"
        )
    }
    public static var defaultQuery = PostEntityQuery()

    public init(_ post: SiteContentGraph.Post) {
        self.id = post.id
        self.displayName = post.title
        self.slug = post.slug
        self.collection = post.collection
        self.siteID = post.siteID
        self.isDraft = post.draft
        self.tags = post.tags
    }
}
```

### `ImageEntity`

```swift
public struct ImageEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String            // "{siteID}:image:{relativePath}"
    public let displayName: String   // fileName
    public let relativePath: String
    public let siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Image" }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(relativePath)")
    }
    public static var defaultQuery = ImageEntityQuery()

    public init(_ image: SiteContentGraph.Image) {
        self.id = image.id
        self.displayName = image.fileName
        self.relativePath = image.relativePath
        self.siteID = image.siteID
    }
}
```

### Queries

All three are `EntityStringQuery`. Shape is identical except for the collection they read from. `PageEntityQuery` shown in full:

```swift
public struct PageEntityQuery: EntityStringQuery {
    @Dependency private var graph: SiteContentGraph
    public init() {}

    private var resolved: SiteContentGraph {
        ContentGraphOverride.scoped ?? graph
    }

    public func entities(for identifiers: [String]) async throws -> [PageEntity] {
        let g = resolved
        var found: [PageEntity] = []
        for id in identifiers {
            if let page = await g.page(id: id) {
                found.append(PageEntity(page))
            }
        }
        return found
    }

    public func entities(matching string: String) async throws -> [PageEntity] {
        let g = resolved
        var matches: [SiteContentGraph.Page] = []
        for siteID in await g.knownSiteIDs() {
            matches.append(contentsOf: await g.searchPages(siteID: siteID, matching: string))
        }
        return matches
            .sorted { $0.lastModified > $1.lastModified }
            .map(PageEntity.init)
    }

    public func suggestedEntities() async throws -> [PageEntity] {
        let g = resolved
        var all: [SiteContentGraph.Page] = []
        for siteID in await g.knownSiteIDs() {
            all.append(contentsOf: await g.pages(for: siteID))
        }
        return all
            .sorted { $0.lastModified > $1.lastModified }
            .map(PageEntity.init)
    }

    public func defaultResult() async -> PageEntity? { nil }
}
```

`PostEntityQuery` swaps `graph.page/pages/searchPages` for `post/posts/searchPosts`.

`ImageEntityQuery` swaps to `image/images`, and `entities(matching:)` performs a manual case-insensitive substring scan on `fileName` and `relativePath` (the graph doesn't expose `searchImages` — A.1 only shipped `searchPages` and `searchPosts`, and adding `searchImages` to the graph is out of scope for A.2):

```swift
public func entities(matching string: String) async throws -> [ImageEntity] {
    let g = resolved
    let needle = string.lowercased()
    var matches: [SiteContentGraph.Image] = []
    for siteID in await g.knownSiteIDs() {
        let scoped = await g.images(for: siteID)
        matches.append(contentsOf: scoped.filter { image in
            if image.fileName.lowercased().contains(needle) { return true }
            if image.relativePath.lowercased().contains(needle) { return true }
            return false
        })
    }
    return matches
        .sorted { $0.lastModified > $1.lastModified }
        .map(ImageEntity.init)
}
```

### Test escape hatch

```swift
// Sources/AnglesiteIntents/ContentGraphOverride.swift

import AnglesiteCore

/// Test-only escape hatch around `@Dependency` resolution of `SiteContentGraph`. Mirrors
/// `SiteOperationsOverride.scoped` (see #104, #127). Tests bind via
/// `$scoped.withValue(graph)` before invoking a query method.
public enum ContentGraphOverride {
    @TaskLocal public static var scoped: SiteContentGraph?
}
```

### Bootstrap (modified)

```swift
public enum AnglesiteIntents {
    public static func bootstrap(contentGraph: SiteContentGraph) async {
        AppDependencyManager.shared.add { () -> SiteContentGraph in contentGraph }
        AppDependencyManager.shared.add { () -> any SiteOperationsService in
            SiteOperations(factory: LiveCommandFactory())
        }
        await SiteStore.shared.setChangeHandler { sites in
            do {
                let outcome = try await SpotlightIndexer.shared.reindex(sites)
                log.info("indexed=\(outcome.indexed, privacy: .public) removed=\(outcome.removed, privacy: .public)")
            } catch {
                log.error("reindex failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try await SiteStore.shared.load()
        } catch {
            log.error("initial load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

`AnglesiteApp` callsites (one or two — DevID and MAS) construct a single `SiteContentGraph()` at app init and pass it in.

## Invariants

1. **Entity id == graph id.** No re-keying between layers. `PageEntity.id == SiteContentGraph.Page.id` for the same content.
2. **Unknown ids are silently skipped** in `entities(for:)`. Mirrors `SiteEntityQuery.entities(for:)`. Reflects the filesystem-ahead-of-graph reality where a Shortcut saved with a stale id should produce "no result" rather than an error.
3. **`suggestedEntities()` returns all entries across all known sites**, sorted by `lastModified` DESC. Deviates from the parent spec's "MRU site" wording — see Non-goals.
4. **`defaultResult()` returns `nil` for all three entity types.** Siri/Shortcuts will ask for the parameter rather than auto-picking.
5. **`entities(matching:)` sorts by `lastModified` DESC** so the most recently changed content is surfaced first when Siri presents candidates.
6. **`@Dependency` resolves to the bootstrap-registered graph** in production; tests bypass via `ContentGraphOverride.scoped`.

## Tests

`Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift` (new). One `struct` per entity type, ~12–13 `@Test` cases each, ~38 total. All tests construct a fresh `SiteContentGraph()`, seed via `await graph.load(...)`, bind the override with `ContentGraphOverride.$scoped.withValue(graph) { ... }`, then invoke the query.

Coverage per entity:

| # | Test | Invariant |
|---|---|---|
| 1 | `displayRepresentation_titleAndSubtitle` | Title + subtitle format |
| 2 | `displayRepresentation_fallsBackToRoute_whenTitleNil` (Page only) | `title ?? route` |
| 3 | `displayRepresentation_includesDraftSuffix` (Post only) | `(draft)` suffix |
| 4 | `entitiesForIds_returnsMatching` | Inv 1 — id lookup |
| 5 | `entitiesForIds_skipsUnknown` | Inv 2 |
| 6 | `entitiesForIds_emptyArrayReturnsEmpty` | edge case |
| 7 | `entitiesMatching_byTitleCaseInsensitive` | fuzzy match |
| 8 | `entitiesMatching_byRouteOrSlug` | per-entity field |
| 9 | `entitiesMatching_byTag` (Post only) | tags search |
| 10 | `entitiesMatching_sortedByLastModifiedDesc` | Inv 5 (split out for unambiguous assertion) |
| 11 | `suggestedEntities_returnsAllAcrossSites_sortedByLastModifiedDesc` | Inv 3 + ordering |
| 12 | `suggestedEntities_emptyGraphReturnsEmpty` | empty case |
| 13 | `defaultResult_returnsNil` | Inv 4 |

PostEntity adds test 3 (draft suffix) and test 9 (tag search) — gets 13 tests. Page adds test 2 (title-nil fallback) — gets 12 tests. Image has neither — gets 11 tests. Total: 36.

The override binding pattern follows the precedent set by `SiteOperationsOverride` in `Tests/AnglesiteIntentsTests/` (see #104, #127). No new test-infrastructure abstractions needed.

## Scope boundaries

**What A.2 does NOT do:**

- No A.3 indexer. No `CSSearchableIndex.indexAppEntities` call. The `IndexedEntity` conformance is in place but no entity is published to Spotlight yet.
- No MCP wiring. A.8 (#142) populates the graph from `LocalSiteRuntime`.
- No new intents that take `PageEntity` / `PostEntity` / `ImageEntity` as a parameter. A.5 (#139) builds those.
- No `searchImages` addition to `SiteContentGraph`. `ImageEntityQuery.entities(matching:)` handles the substring scan locally.
- No mutation. All queries are read-only against the graph.

## Acceptance criteria

- [ ] `Sources/AnglesiteIntents/ContentEntities.swift` exists with all three entities + three queries.
- [ ] `Sources/AnglesiteIntents/ContentGraphOverride.swift` exists.
- [ ] `Sources/AnglesiteIntents/Bootstrap.swift` updated; `AnglesiteApp` callsites updated to pass a `SiteContentGraph` instance.
- [ ] `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift` exists with the ~36 tests above.
- [ ] `swift test --package-path .` passes (no regressions to the existing suite — 23 `SiteContentGraphTests` from #136 + the new `ContentEntitiesTests` all green).
- [ ] Both Xcode schemes (`Anglesite`, `AnglesiteMAS`) still build clean with the bootstrap signature change.
- [ ] No new dependencies.

## Open follow-ups (deferred)

- **A.3** (#144) — wire `ContentSpotlightIndexer` to publish these entities to Spotlight via the `SiteContentGraph` change handler.
- **Image search in graph** — if more callers need it, add `SiteContentGraph.searchImages` to keep search logic centralized; for now `ImageEntityQuery` handles it locally.
- **Icons in `DisplayRepresentation`** — page favicon, image thumbnail. Deferred until Siri-resolution behavior is validated end-to-end.
- **MRU tracking** — if `suggestedEntities()` empirically surfaces too much content, revisit with explicit `lastFocusedAt` on `SiteStore.Site` (touched by `SiteWindow.becomeKey`).
