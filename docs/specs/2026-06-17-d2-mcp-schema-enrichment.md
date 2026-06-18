# D.2 — MCP Schema Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enrich the existing App Intent / `AppEntity` schema so macOS 27's `mcpbridge` auto-derives agent-chainable MCP tools (closing #163), serving Siri, Shortcuts, and MCP at once.

**Architecture:** Three additive changes to the `AnglesiteIntents` SPM module — (F-1) promote entity fields to `@Property`, (F-2) a uniform `ContentMatchEntity` projection so `SearchContentIntent` returns matched entities, (F-3) `ReturnsValue<…?>` on the create intents. All logic goes through pure static helpers (mirroring `ContentDialogs` / `SearchContentIntent.dialog`) so it is unit-testable without the AppIntents runtime. No hand-written MCP descriptors (deferred to D.5/#166).

**Tech Stack:** Swift 6.4 / Xcode 27, Apple `AppIntents`, Swift Testing (`@Test`), `SiteContentGraph` (Core).

## Global Constraints

- Target **macOS 27+**; toolchain **Xcode 27 / Swift 6.4**. macOS-27-only intent APIs (`LongRunningIntent`, `performBackgroundTask`) stay behind `#if compiler(>=6.4)` — do not remove the fallback arms (#128).
- **No frameworks beyond Apple's.**
- New tests use **Swift Testing** (`@Test`/`#expect`/`#require`), under the `AppIntentsTests` root suite (`.serialized`).
- New source files live under `Sources/AnglesiteIntents/` — globbed by the SPM package product; **no `project.yml` edit, no `xcodegen` change** needed for source additions.
- **Verification gate (every commit):** `swift test --package-path .` filtered to the touched suites must pass. **Final task only:** build BOTH schemes via `xcodebuild` (`Anglesite` + `AnglesiteMAS`) — `swift test` alone does not prove the `.app` targets link.
- **Worktree:** already created at `.claude/worktrees/163-d2-mcp-schema`. Before any `xcodebuild`: run `xcodegen generate` and `export ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite`.
- Branch: `worktree-163-d2-mcp-schema`. Commit after each task.

---

### Task 1: F-1 — Promote entity fields to `@Property`

Promote the audit-named fields from plain `let` to `@Property(title:) var` so they enter the derived MCP/Shortcuts schema as typed, extractable values. Behaviorally identical for value reads — existing `ContentEntitiesTests` are the regression guard; add explicit round-trip assertions for Post/Image to lock the contract.

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift`
- Test: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`

**Interfaces:**
- Consumes: `SiteContentGraph.Page/Post/Image`, `ContentGraphOverride.$scoped`, fixtures `AppIntentsTests.gPage/gPost/gImage`, `aSite`.
- Produces: `PageEntity.route/siteID`, `PostEntity.slug/collection/siteID`, `ImageEntity.relativePath/siteID` are now `@Property var` (same names/types). No signature changes to consumers.

- [ ] **Step 1: Add a failing round-trip test for Post and Image promoted fields**

In `ContentEntitiesTests.swift`, inside the existing `PostEntityQuery` suite (and `ImageEntityQuery` suite) add:

```swift
@Test("PostEntity round-trip exposes slug, collection, siteID")
func postRoundTripFields() async throws {
    let graph = SiteContentGraph()
    let p = AppIntentsTests.gPost(slug: "hello-world", collection: "blog")
    await graph.upsertPost(p)
    try await ContentGraphOverride.$scoped.withValue(graph) {
        let r = try await PostEntityQuery().entities(for: [p.id])
        #expect(r.first?.slug == "hello-world")
        #expect(r.first?.collection == "blog")
        #expect(r.first?.siteID == AppIntentsTests.aSite)
    }
}

@Test("ImageEntity round-trip exposes relativePath, siteID")
func imageRoundTripFields() async throws {
    let graph = SiteContentGraph()
    let i = AppIntentsTests.gImage(relativePath: "public/images/hero.jpg")
    await graph.upsertImage(i)
    try await ContentGraphOverride.$scoped.withValue(graph) {
        let r = try await ImageEntityQuery().entities(for: [i.id])
        #expect(r.first?.relativePath == "public/images/hero.jpg")
        #expect(r.first?.siteID == AppIntentsTests.aSite)
    }
}
```

> If `upsertPost`/`upsertImage` don't exist, use `graph.load(siteID:pages:posts:images:)` with the single fixture in the right array (the load form is used elsewhere in `ContentIntentsTests`). Verify the actor API name with: `grep -n "func upsert\|func load" Sources/AnglesiteCore/SiteContentGraph.swift`.

- [ ] **Step 2: Run to verify the new tests pass against the current `let` fields (baseline green)**

Run: `swift test --package-path . --filter ContentEntitiesTests 2>&1 | tail -20`
Expected: PASS (these fields already exist as `let`; this pins the contract before the refactor).

- [ ] **Step 3: Promote the fields to `@Property`**

In `ContentEntities.swift`, change the field declarations (keep `id` and `displayName` as plain `let`; keep each `init(_:)` body unchanged):

```swift
// PageEntity
public let id: String
public let displayName: String
@Property(title: "Route") public var route: String
@Property(title: "Site") public var siteID: String
```

```swift
// PostEntity
public let id: String
public let displayName: String
@Property(title: "Slug") public var slug: String
@Property(title: "Collection") public var collection: String
public let isDraft: Bool
public let tags: [String]
@Property(title: "Site") public var siteID: String
```

```swift
// ImageEntity
public let id: String
public let displayName: String
@Property(title: "Path") public var relativePath: String
public let usedOnPages: [String]
@Property(title: "Site") public var siteID: String
```

> `usedOnPages`, `isDraft`, `tags` stay plain `let` (deliberately out of scope — see spec). `@Property` requires `var`; the structs stay value types and each existing `init(_:)` already assigns every field, so no init change is needed.

- [ ] **Step 4: Run the full intents entity suite + confirm no regressions**

Run: `swift test --package-path . --filter ContentEntitiesTests 2>&1 | tail -20`
Expected: PASS (new + existing `displayRepresentation`/`entities(for:)` tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/ContentEntities.swift Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift
git commit -m "feat(intents): F-1 promote entity fields to @Property for MCP chaining (#163)

route/siteID (Page), slug/collection/siteID (Post), relativePath/siteID
(Image) now enter the auto-derived schema as typed values. Re-resolution
stays id-based, so the schema growth is additive.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: F-2 — `ContentMatchEntity` + structured `SearchContentIntent` return

Introduce a uniform projection so the three-type search returns a single `ReturnsValue<[ContentMatchEntity]>`. The spoken count dialog is preserved and derived from the same match list (DRY — one search, no double-query).

**Files:**
- Create: `Sources/AnglesiteIntents/ContentMatchEntity.swift`
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift` (`SearchContentIntent`)
- Create: `Tests/AnglesiteIntentsTests/ContentMatchEntityTests.swift`
- Test: `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift` (existing `searchHelper` test stays valid via the delegating `dialog` helper)

**Interfaces:**
- Consumes: `PageEntity`/`PostEntity`/`ImageEntity` (Task 1), their `id`/`displayName`/`route`/`slug`/`relativePath`/`siteID`; `SiteContentGraph.searchPages/searchPosts/searchImages`; the `PageEntityQuery`/`PostEntityQuery`/`ImageEntityQuery` (for id round-trip).
- Produces:
  - `enum ContentMatchKind: String, AppEnum { case page, post, image }`
  - `struct ContentMatchEntity: AppEntity` with `id, kind, title, path, siteID` and inits `init(_:PageEntity)`, `init(_:PostEntity)`, `init(_:ImageEntity)`.
  - `struct ContentMatchEntityQuery: EntityQuery`.
  - `SearchContentIntent.matches(graph:siteID:query:) async -> [ContentMatchEntity]` (new static helper).
  - `SearchContentIntent.perform` now `& ReturnsValue<[ContentMatchEntity]>`.

- [ ] **Step 1: Write the failing test for the projection + query**

Create `Tests/AnglesiteIntentsTests/ContentMatchEntityTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("ContentMatchEntity")
    struct ContentMatchEntityTests {
        @Test("projects each entity kind to a uniform shape")
        func projectsKinds() {
            let pm = ContentMatchEntity(PageEntity(AppIntentsTests.gPage(route: "/about", title: "About")))
            #expect(pm.kind == .page)
            #expect(pm.title == "About")
            #expect(pm.path == "/about")
            #expect(pm.id == "\(AppIntentsTests.aSite):page:/about")

            let som = ContentMatchEntity(PostEntity(AppIntentsTests.gPost(slug: "hello-world", title: "Hello World", collection: "blog")))
            #expect(som.kind == .post)
            #expect(som.path == "hello-world")

            let im = ContentMatchEntity(ImageEntity(AppIntentsTests.gImage(relativePath: "public/images/hero.jpg")))
            #expect(im.kind == .image)
            #expect(im.path == "public/images/hero.jpg")
        }

        @Test("query resolves a mixed id list back to the right kinds, in input order")
        func queryResolvesMixedIDs() async throws {
            let graph = SiteContentGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage(route: "/about", title: "About")],
                posts: [AppIntentsTests.gPost(slug: "hello-world")],
                images: [AppIntentsTests.gImage(relativePath: "public/images/hero.jpg")]
            )
            let ids = [
                "\(AppIntentsTests.aSite):image:public/images/hero.jpg",
                "\(AppIntentsTests.aSite):page:/about",
                "\(AppIntentsTests.aSite):post:hello-world",
            ]
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let r = try await ContentMatchEntityQuery().entities(for: ids)
                #expect(r.map(\.id) == ids)               // input order preserved
                #expect(r.map(\.kind) == [.image, .page, .post])
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter ContentMatchEntity 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ContentMatchEntity' in scope`.

- [ ] **Step 3: Create `ContentMatchEntity.swift`**

```swift
import AppIntents
import AnglesiteCore

/// The kind of content a search match refers to. An `AppEnum` so it appears as a typed
/// field in the auto-derived MCP/Shortcuts schema (not just a string).
public enum ContentMatchKind: String, AppEnum, Sendable {
    case page, post, image

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Content Kind" }
    public static var caseDisplayRepresentations: [ContentMatchKind: DisplayRepresentation] {
        [.page: "Page", .post: "Post", .image: "Image"]
    }
}

/// A uniform projection of a `PageEntity` / `PostEntity` / `ImageEntity` search hit.
/// `id` is the underlying entity's id ("{siteID}:{kind}:{path}"), so an agent can hand a
/// match straight to any intent that resolves the concrete type. `SearchContentIntent`
/// returns these so an agent can search-then-act across all three content kinds at once.
public struct ContentMatchEntity: AppEntity, Identifiable, Sendable {
    public let id: String
    @Property(title: "Kind") public var kind: ContentMatchKind
    @Property(title: "Title") public var title: String
    @Property(title: "Path") public var path: String   // route | slug | relativePath
    @Property(title: "Site") public var siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Content Match" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(kind.rawValue): \(path)")
    }

    public static let defaultQuery = ContentMatchEntityQuery()

    public init(id: String, kind: ContentMatchKind, title: String, path: String, siteID: String) {
        self.id = id; self.kind = kind; self.title = title; self.path = path; self.siteID = siteID
    }

    public init(_ p: PageEntity) {
        self.init(id: p.id, kind: .page, title: p.displayName, path: p.route, siteID: p.siteID)
    }
    public init(_ p: PostEntity) {
        self.init(id: p.id, kind: .post, title: p.displayName, path: p.slug, siteID: p.siteID)
    }
    public init(_ i: ImageEntity) {
        self.init(id: i.id, kind: .image, title: i.displayName, path: i.relativePath, siteID: i.siteID)
    }
}

/// Resolves `ContentMatchEntity` ids by routing each id to the concrete entity query based on
/// its ":page:" / ":post:" / ":image:" segment, then projecting. Input order is preserved.
public struct ContentMatchEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ContentMatchEntity] {
        let pages = try await PageEntityQuery()
            .entities(for: identifiers.filter { $0.contains(":page:") }).map(ContentMatchEntity.init)
        let posts = try await PostEntityQuery()
            .entities(for: identifiers.filter { $0.contains(":post:") }).map(ContentMatchEntity.init)
        let images = try await ImageEntityQuery()
            .entities(for: identifiers.filter { $0.contains(":image:") }).map(ContentMatchEntity.init)
        let byID = Dictionary(uniqueKeysWithValues: (pages + posts + images).map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0] }
    }

    public func suggestedEntities() async throws -> [ContentMatchEntity] { [] }
}
```

- [ ] **Step 4: Run the projection/query test to verify it passes**

Run: `swift test --package-path . --filter ContentMatchEntity 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Write the failing test for the search helper + chaining**

In `ContentIntentsTests.swift`, add inside the `ContentIntentsTests` struct:

```swift
@Test("SearchContentIntent.matches returns a uniform list across kinds")
func searchMatchesHelper() async {
    let graph = SiteContentGraph()
    await graph.load(
        siteID: AppIntentsTests.aSite,
        pages: [AppIntentsTests.gPage(route: "/about", title: "About")],
        posts: [AppIntentsTests.gPost(slug: "about-us", title: "About Us")],
        images: []
    )
    let matches = await SearchContentIntent.matches(graph: graph, siteID: AppIntentsTests.aSite, query: "about")
    #expect(matches.map(\.kind) == [.page, .post])
    #expect(matches.first { $0.kind == .page }?.path == "/about")
}

@Test("search match path is the route and resolves back to a page (chaining)")
func searchMatchChainsToPage() async throws {
    let graph = SiteContentGraph()
    let p = AppIntentsTests.gPage(route: "/about", title: "About")
    await graph.load(siteID: AppIntentsTests.aSite, pages: [p], posts: [], images: [])
    try await ContentGraphOverride.$scoped.withValue(graph) {
        let matches = await SearchContentIntent.matches(graph: graph, siteID: AppIntentsTests.aSite, query: "about")
        let pageMatch = try #require(matches.first { $0.kind == .page })
        #expect(pageMatch.path == "/about")
        let resolved = try await ContentMatchEntityQuery().entities(for: [pageMatch.id])
        #expect(resolved.map(\.id) == [p.id])
    }
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `swift test --package-path . --filter ContentIntents 2>&1 | tail -20`
Expected: FAIL — `type 'SearchContentIntent' has no member 'matches'`.

- [ ] **Step 7: Add `matches`, refactor `dialog`, and return the value from `perform`**

In `ContentIntents.swift`, replace the `SearchContentIntent.perform` and `dialog(...)` with:

```swift
public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[ContentMatchEntity]> {
    let g = ContentGraphOverride.scoped ?? graph
    let matches = await Self.matches(graph: g, siteID: site.id, query: query)
    return .result(value: matches, dialog: IntentDialog(stringLiteral: Self.dialog(for: matches, query: query)))
}

/// Gather matches from the graph as a uniform list. Static + graph-injected so it's
/// unit-testable without the AppIntents runtime (mirrors the prior `dialog` helper).
static func matches(graph: SiteContentGraph, siteID: String, query: String) async -> [ContentMatchEntity] {
    let pages = await graph.searchPages(siteID: siteID, matching: query).map { ContentMatchEntity(PageEntity($0)) }
    let posts = await graph.searchPosts(siteID: siteID, matching: query).map { ContentMatchEntity(PostEntity($0)) }
    let images = await graph.searchImages(siteID: siteID, matching: query).map { ContentMatchEntity(ImageEntity($0)) }
    return pages + posts + images
}

/// Spoken count dialog, derived from the already-gathered matches (single search path).
static func dialog(for matches: [ContentMatchEntity], query: String) -> String {
    ContentDialogs.search(
        query: query,
        pageCount: matches.filter { $0.kind == .page }.count,
        postCount: matches.filter { $0.kind == .post }.count,
        imageCount: matches.filter { $0.kind == .image }.count
    )
}

/// Back-compat overload used by the existing `searchHelper` test: gather + format in one call.
static func dialog(graph: SiteContentGraph, siteID: String, query: String) async -> String {
    dialog(for: await matches(graph: graph, siteID: siteID, query: query), query: query)
}
```

> The existing `searchHelper` test calls `SearchContentIntent.dialog(graph:siteID:query:)` and still passes unchanged (it now delegates through `matches`).

- [ ] **Step 8: Run the search/chaining + existing dialog tests**

Run: `swift test --package-path . --filter ContentIntents 2>&1 | tail -20`
Expected: PASS (new `searchMatchesHelper`, `searchMatchChainsToPage`, and the unchanged `searchHelper`/`searchDialog`).

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteIntents/ContentMatchEntity.swift Sources/AnglesiteIntents/ContentIntents.swift Tests/AnglesiteIntentsTests/ContentMatchEntityTests.swift Tests/AnglesiteIntentsTests/ContentIntentsTests.swift
git commit -m "feat(intents): F-2 SearchContentIntent returns ContentMatchEntity list (#163)

Uniform projection over page/post/image hits → ReturnsValue<[ContentMatchEntity]>,
so an agent can search-then-act. Dialog preserved, derived from the same matches.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: F-3 — Structured return from the create intents

`AddPageIntent` / `AddPostIntent` return the created entity (or `nil` on failure) so an agent can create-then-preview/deploy. Logic lives in pure static factories (testable directly; the opaque `perform()` result is never introspected — matching the codebase's chaining-test convention).

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift` (add explicit inits to `PageEntity`/`PostEntity`)
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift` (`AddPageIntent`/`AddPostIntent` + `import Foundation`)
- Test: `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift`

**Interfaces:**
- Consumes: `ContentCreateResult.created(filePath:identifier:)` / `.siteNotFound` / `.failed(reason:)` (Core), `PageEntity`/`PostEntity` inits.
- Produces:
  - `PageEntity.init(id:displayName:route:siteID:)`, `PostEntity.init(id:displayName:slug:collection:siteID:isDraft:tags:)`.
  - `AddPageIntent.createdPage(_:siteID:name:) -> PageEntity?`
  - `AddPostIntent.createdPost(_:siteID:title:collection:) -> PostEntity?`
  - `AddPageIntent.perform` now `& ReturnsValue<PageEntity?>`; `AddPostIntent.perform` now `& ReturnsValue<PostEntity?>`.

- [ ] **Step 1: Write the failing test for the create factories**

In `ContentIntentsTests.swift`, add inside the `ContentIntentsTests` struct:

```swift
@Test("createdPage builds a PageEntity from a successful result, nil on failure")
func createdPageFactory() {
    let ok = ContentCreateResult.created(filePath: "src/pages/about.astro", identifier: "/about")
    let e = AddPageIntent.createdPage(ok, siteID: AppIntentsTests.aSite, name: "About")
    #expect(e?.id == "\(AppIntentsTests.aSite):page:/about")
    #expect(e?.route == "/about")
    #expect(e?.displayName == "About")
    #expect(AddPageIntent.createdPage(.siteNotFound, siteID: AppIntentsTests.aSite, name: "About") == nil)
    #expect(AddPageIntent.createdPage(.failed(reason: "x"), siteID: AppIntentsTests.aSite, name: "About") == nil)
}

@Test("createdPost builds a PostEntity; collection from input, else parsed from filePath")
func createdPostFactory() {
    let ok = ContentCreateResult.created(filePath: "src/content/notes/hello.md", identifier: "hello")
    let withInput = AddPostIntent.createdPost(ok, siteID: AppIntentsTests.aSite, title: "Hello", collection: "blog")
    #expect(withInput?.id == "\(AppIntentsTests.aSite):post:hello")
    #expect(withInput?.slug == "hello")
    #expect(withInput?.collection == "blog")          // input wins
    let parsed = AddPostIntent.createdPost(ok, siteID: AppIntentsTests.aSite, title: "Hello", collection: nil)
    #expect(parsed?.collection == "notes")            // parsed from filePath
    #expect(AddPostIntent.createdPost(.failed(reason: "x"), siteID: AppIntentsTests.aSite, title: "Hello", collection: nil) == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter ContentIntents 2>&1 | tail -20`
Expected: FAIL — `type 'AddPageIntent' has no member 'createdPage'`.

- [ ] **Step 3: Add explicit entity inits**

In `ContentEntities.swift`, add to `PageEntity` (alongside `init(_ page:)`):

```swift
public init(id: String, displayName: String, route: String, siteID: String) {
    self.id = id; self.displayName = displayName; self.route = route; self.siteID = siteID
}
```

Add to `PostEntity`:

```swift
public init(id: String, displayName: String, slug: String, collection: String,
            siteID: String, isDraft: Bool = true, tags: [String] = []) {
    self.id = id; self.displayName = displayName; self.slug = slug
    self.collection = collection; self.siteID = siteID; self.isDraft = isDraft; self.tags = tags
}
```

- [ ] **Step 4: Add the factories and wire the returns in `ContentIntents.swift`**

At the top of `ContentIntents.swift`, add `import Foundation` (for `NSString` path parsing).

Add the factories (place them next to the respective intents):

```swift
extension AddPageIntent {
    /// Reconstruct the created page from inputs + result; nil when the create failed.
    static func createdPage(_ result: ContentCreateResult, siteID: String, name: String) -> PageEntity? {
        guard case let .created(_, identifier) = result else { return nil }
        return PageEntity(id: "\(siteID):page:\(identifier)", displayName: name, route: identifier, siteID: siteID)
    }
}

extension AddPostIntent {
    /// Reconstruct the created post; collection from the input when supplied, else parsed
    /// from the created file's parent directory.
    static func createdPost(_ result: ContentCreateResult, siteID: String, title: String, collection: String?) -> PostEntity? {
        guard case let .created(filePath, identifier) = result else { return nil }
        let coll = (collection?.isEmpty == false)
            ? collection!
            : (filePath as NSString).deletingLastPathComponent.lastPathComponent
        return PostEntity(id: "\(siteID):post:\(identifier)", displayName: title, slug: identifier, collection: coll, siteID: siteID)
    }
}
```

Change `AddPageIntent.perform`'s signature and final return:

```swift
public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<PageEntity?> {
    // ... unchanged service-call body producing `result: ContentCreateResult` ...
    return .result(
        value: Self.createdPage(result, siteID: site.id, name: name),
        dialog: IntentDialog(stringLiteral: ContentDialogs.created(result, kind: .page, siteName: site.displayName))
    )
}
```

Change `AddPostIntent.perform` the same way:

```swift
public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<PostEntity?> {
    // ... unchanged service-call body producing `result: ContentCreateResult` ...
    return .result(
        value: Self.createdPost(result, siteID: site.id, title: title2, collection: collection),
        dialog: IntentDialog(stringLiteral: ContentDialogs.created(result, kind: .post, siteName: site.displayName))
    )
}
```

> Leave the `#if compiler(>=6.4)` `performBackgroundTask` / `LongRunningIntent` structure and the `ContentOperationsOverride.scoped` branch untouched — only the return type and the final `.result(...)` change. The existing `addPageForwards` / `addPostForwards` / `createFailureIsHandled` tests still hold (they assert via the fake's call log and that `perform()` doesn't throw).

- [ ] **Step 5: Run the create tests to verify they pass**

Run: `swift test --package-path . --filter ContentIntents 2>&1 | tail -20`
Expected: PASS (new factory tests + the three existing create tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteIntents/ContentEntities.swift Sources/AnglesiteIntents/ContentIntents.swift Tests/AnglesiteIntentsTests/ContentIntentsTests.swift
git commit -m "feat(intents): F-3 create intents return the created entity (#163)

AddPage/AddPostIntent gain ReturnsValue<PageEntity?>/<PostEntity?> so an agent
can create-then-preview/deploy; nil + dialog on failure preserves Siri UX.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Full-suite verification + both-scheme build + PR

**Files:** none (verification + integration).

- [ ] **Step 1: Run the entire AnglesiteIntents suite**

Run: `swift test --package-path . --filter AnglesiteIntentsTests 2>&1 | tail -25`
Expected: PASS — 145 prior `@Test` + the new D.2 tests, 0 failures. (The plugin-path e2e suites `MCPClientHTTPEndToEndTests`/`AppliesEditEndToEndTests` are unrelated and fail only when the plugin checkout is absent — #222.)

- [ ] **Step 2: Generate the project and build BOTH schemes**

```bash
export ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **` for both. This is the F-1 schema-bump safety check — both `.app` targets link with the `@Property` change.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin worktree-163-d2-mcp-schema
gh pr create --title "feat(intents): D.2 — MCP-readiness schema enrichment (#163)" \
  --body "$(cat <<'EOF'
## D.2 — MCP Tool Descriptors via schema enrichment (#163, Phase D #135)

Per the D.1 audit, macOS 27's `mcpbridge` auto-derives MCP tools from intent schema,
so D.2 enriches that schema instead of hand-writing descriptors (deferred to D.5/#166).

- **F-1** — `route`/`siteID` (Page), `slug`/`collection`/`siteID` (Post), `relativePath`/`siteID` (Image) promoted to `@Property`. Re-resolution stays id-based → additive.
- **F-2** — `ContentMatchEntity` uniform projection; `SearchContentIntent` returns `ReturnsValue<[ContentMatchEntity]>`; dialog preserved.
- **F-3** — `AddPage`/`AddPostIntent` return `ReturnsValue<PageEntity?>`/`<PostEntity?>`; nil + dialog on failure.

Design: `docs/specs/2026-06-17-d2-mcp-tool-descriptors-design.md`.

### Testing
- `AnglesiteIntents` suite green (incl. new F-1 round-trip, F-2 projection/query/chaining, F-3 factory tests).
- Both schemes build (`Anglesite` + `AnglesiteMAS`).
- Manual Shortcuts-persistence smoke deferred to D.5 (#166).

Closes #163.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
Expected: PR URL printed; CI (build-test, JS overlay, ThreadSanitizer, xcodeproj-sync) goes green.

## Self-Review

- **Spec coverage:** F-1 → Task 1; F-2 (`ContentMatchEntity` + `SearchContentIntent` return) → Task 2; F-3 (create returns) → Task 3; dual-scheme build + deferred custom descriptors + D.5 smoke note → Task 4 / spec out-of-scope section. All spec sections map to a task.
- **Placeholder scan:** none — every code/test step shows full code; the one runtime check (`upsert*` vs `load` API name) has an explicit `grep` fallback.
- **Type consistency:** `ContentMatchEntity`/`ContentMatchKind`/`ContentMatchEntityQuery`, `matches(graph:siteID:query:)`, `dialog(for:query:)`, `createdPage(_:siteID:name:)`, `createdPost(_:siteID:title:collection:)`, and the new `PageEntity`/`PostEntity` inits are defined where first used and referenced with identical signatures downstream.
