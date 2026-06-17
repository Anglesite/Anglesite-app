# D.2 Intent Schema Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enrich the Anglesite App Intent / `AppEntity` schema so macOS 27's `mcpbridge` auto-derives agent-usable MCP tools — typed extractable entity fields, structured create-intent returns, and a unified search result — then record that no hand-written MCP descriptors are needed.

**Architecture:** Three independent, additive changes to the `AnglesiteIntents` module, each landing as its own stacked PR into `main`: F-1 promotes entity fields to `@Property`; F-3 makes the create intents return the created entity via `ReturnsValue<T>`; F-2 adds a flattened `ContentSearchResultEntity` and gives `SearchContentIntent` a `ReturnsValue<[ContentSearchResultEntity]>`. All are covered by the existing Swift Testing seams (`ContentGraphOverride` / `ContentOperationsOverride`) — no AppIntents runtime, no hosted app target, so everything runs under `swift test` on CI.

**Tech Stack:** Swift 6.4 / AppIntents (macOS 27), Swift Testing (`@Test`/`@Suite`), SwiftPM (`swift test`).

**Spec:** [`docs/specs/2026-06-17-d2-intent-mcp-enrichment-design.md`](./2026-06-17-d2-intent-mcp-enrichment-design.md)

## Global Constraints

- **No frameworks beyond Apple's** — AppIntents + Swift Testing only; no new dependencies.
- **Strictly additive schema changes** — never rename or remove an existing `AppEntity` field, and never change `id`, `displayName`, or `displayRepresentation`. Already-donated Shortcuts interactions resolve by `id`, which must stay stable.
- **Entity id formulas are fixed** (must match `SiteContentGraph`): page `"{siteID}:page:{route}"`, post `"{siteID}:post:{slug}"`, image `"{siteID}:image:{relativePath}"`.
- **Test seams** — bypass `@Dependency` via `ContentGraphOverride.$scoped.withValue(...)` (reads) and `ContentOperationsOverride.$scoped.withValue(...)` (creates). Direct `@Dependency` access outside the AppIntents runtime crashes.
- **Tests assert via fakes / reconstructed entities**, never by reading `perform()`'s opaque `ReturnsValue` result (the return type is not destructurable in a unit test — this is why every "does it return the entity?" check is done against a pure helper, not `perform()`).
- **Dialog wording is frozen** — `ContentDialogs.search(...)` / `.status(...)` output strings must stay byte-identical (existing tests assert exact strings).
- **Worktree:** all work happens in `.claude/worktrees/d2-intent-enrichment` (already created off `main`, branch `feat/d2-intent-mcp-enrichment`, which already holds the spec + this plan commit). Run `swift test` from that directory.

## PR sequencing

Three stacked PRs, in this order (each builds on the prior so the schema compounds):

1. **PR 1 — F-1** (`@Property` promotion). Base: current branch (`feat/d2-intent-mcp-enrichment`, holds spec+plan).
2. **PR 2 — F-3** (create-intent structured returns). Branch off PR 1's head.
3. **PR 3 — F-2** (unified search result + closeout). Branch off PR 2's head.

Branch/commit/PR mechanics are handled by the execution skill; this plan defines the code and tests.

## Test command reference

- Run one suite: `swift test --package-path . --filter <SuiteName>` (e.g. `--filter ContentEntities`).
- Run one test by function name: `swift test --package-path . --filter <funcName>`.
- Full intents verification at PR end: `swift test --package-path . 2>&1 | tail -40`.
  - **Expected baseline:** all `AnglesiteIntents` / `AnglesiteCore` / `AnglesiteBridge` suites pass; the two plugin-path e2e tests (`MCPClientHTTPEndToEndTests`, `AppliesEditEndToEndTests`) fail when the sibling plugin checkout is absent (known #222) — that is the unchanged baseline, not a regression from this work.

---

## PR 1 — F-1: `@Property` promotion

**File structure:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift` — promote disambiguating fields on `PageEntity`, `PostEntity`, `ImageEntity` from `let` to `@Property var`.
- Test: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift` — add a suite asserting promoted fields survive construction.

### Task 1.1: Promote entity fields to `@Property`

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift`
- Test: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`

**Interfaces:**
- Produces: `PageEntity.route`, `PageEntity.siteID`, `PostEntity.slug`, `PostEntity.collection`, `PostEntity.siteID`, `ImageEntity.relativePath`, `ImageEntity.siteID` as `@Property`-annotated `public var`s (same names, same types, same values — only the storage annotation changes). `id`, `displayName`, `displayRepresentation`, the `init(_:)` initializers, and all queries are unchanged.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift` (inside `extension AppIntentsTests`, after the fixtures, before `PageEntityQueryTests`):

```swift
@Suite("PropertyPromotion (F-1)")
struct PropertyPromotionTests {
    @Test("promoted PageEntity fields round-trip through construction")
    func pageFields() {
        let e = PageEntity(AppIntentsTests.gPage(route: "/about", title: "About"))
        #expect(e.route == "/about")
        #expect(e.siteID == AppIntentsTests.aSite)
        #expect(e.id == "\(AppIntentsTests.aSite):page:/about")  // id unchanged
    }

    @Test("promoted PostEntity fields round-trip through construction")
    func postFields() {
        let e = PostEntity(AppIntentsTests.gPost(slug: "hello-world", collection: "blog"))
        #expect(e.slug == "hello-world")
        #expect(e.collection == "blog")
        #expect(e.siteID == AppIntentsTests.aSite)
    }

    @Test("promoted ImageEntity fields round-trip through construction")
    func imageFields() {
        let e = ImageEntity(AppIntentsTests.gImage(relativePath: "public/images/hero.jpg"))
        #expect(e.relativePath == "public/images/hero.jpg")
        #expect(e.siteID == AppIntentsTests.aSite)
    }
}
```

- [ ] **Step 2: Run the test to verify it compiles+passes already (baseline) — fields are currently `let`**

Run: `swift test --package-path . --filter PropertyPromotion`
Expected: PASS (the fields are readable today as `let`). This test is a *regression guard* — it must still pass after the `let`→`@Property` change. (If you prefer a strict red phase, temporarily rename a field in the test to see it fail, then revert.)

- [ ] **Step 3: Promote the fields in `ContentEntities.swift`**

In `PageEntity`, change:
```swift
public let route: String
public let siteID: String
```
to:
```swift
@Property(title: "Route") public var route: String
@Property(title: "Site ID") public var siteID: String
```
Leave `public let id`, `public let displayName`, and the `init(_ page:)` body unchanged (`self.route = page.route` / `self.siteID = page.siteID` still compile — `@Property` is assignable in `init`).

In `PostEntity`, change `public let slug`, `public let collection`, `public let siteID` to:
```swift
@Property(title: "Slug") public var slug: String
@Property(title: "Collection") public var collection: String
@Property(title: "Site ID") public var siteID: String
```
Leave `isDraft` and `tags` as plain `let` (not part of F-1).

In `ImageEntity`, change `public let relativePath`, `public let siteID` to:
```swift
@Property(title: "Relative Path") public var relativePath: String
@Property(title: "Site ID") public var siteID: String
```
Leave `usedOnPages` a plain `let` (intentionally out of schema — keep its existing comment).

- [ ] **Step 4: Run the promotion test + the full entity suite**

Run: `swift test --package-path . --filter ContentEntities`
Expected: PASS — `PropertyPromotion` plus all existing `PageEntityQuery` / `PostEntityQuery` / `ImageEntityQuery` tests stay green (construction, search, and id resolution are unaffected).

- [ ] **Step 5: Full intents-suite sanity**

Run: `swift test --package-path . --filter AppIntentsTests`
Expected: PASS for all nested intents suites (the `extension AppIntentsTests` suites share that root). No behavior change anywhere else.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteIntents/ContentEntities.swift Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift
git commit -m "feat(intents): F-1 — promote entity fields to @Property for typed MCP chaining (#163)

route/siteID (Page), slug/collection/siteID (Post), relativePath/siteID (Image)
become @Property so mcpbridge-derived tools expose them as extractable typed
fields. Strictly additive: id/displayName/displayRepresentation unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## PR 2 — F-3: create intents return the created entity

**File structure:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift` — add a direct field initializer and a `make(...)` factory to `PageEntity` and `PostEntity`.
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift` — `AddPageIntent` / `AddPostIntent` gain `ReturnsValue<…>` and call the factory.
- Test: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift` (factory tests) and `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift` + `IntentChainingTests.swift` (intent + chaining).

### Task 2.1: `PageEntity` create-factory + `AddPageIntent` structured return

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift`
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift:113-154` (`AddPageIntent`)
- Test: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`, `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift`

**Interfaces:**
- Consumes: `ContentCreateResult` (`.created(filePath:identifier:)` / `.siteNotFound` / `.failed(reason:)`) from `AnglesiteCore`.
- Produces:
  - `PageEntity.init(id: String, displayName: String, route: String, siteID: String)` — direct field init.
  - `static func PageEntity.make(siteID: String, name: String, requestedRoute: String?, result: ContentCreateResult) -> PageEntity` — success uses `result`'s `identifier` as the route; failure falls back to `requestedRoute ?? ""`. Always returns an entity (never optional).
  - `AddPageIntent.perform()` returns `some IntentResult & ProvidesDialog & ReturnsValue<PageEntity>`.

- [ ] **Step 1: Write the failing factory test**

Add to `ContentEntitiesTests.swift` inside the `PropertyPromotion` neighbor area, a new suite:

```swift
@Suite("CreateFactory.Page (F-3)")
struct CreatePageFactoryTests {
    @Test("success: route comes from the created identifier; id matches graph formula")
    func success() {
        let e = PageEntity.make(
            siteID: AppIntentsTests.aSite, name: "About Us", requestedRoute: nil,
            result: .created(filePath: "src/pages/about.astro", identifier: "/about"))
        #expect(e.route == "/about")
        #expect(e.siteID == AppIntentsTests.aSite)
        #expect(e.displayName == "About Us")
        #expect(e.id == "\(AppIntentsTests.aSite):page:/about")
    }

    @Test("failure: best-effort entity from the requested route")
    func failure() {
        let e = PageEntity.make(
            siteID: AppIntentsTests.aSite, name: "About", requestedRoute: "/about",
            result: .failed(reason: "boom"))
        #expect(e.route == "/about")
        #expect(e.id == "\(AppIntentsTests.aSite):page:/about")
        #expect(e.displayName == "About")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter CreateFactory.Page`
Expected: FAIL — `PageEntity.make` / `PageEntity.init(id:displayName:route:siteID:)` do not exist (compile error).

- [ ] **Step 3: Implement the init + factory in `ContentEntities.swift`**

Add to `PageEntity` (after the existing `init(_ page:)`):

```swift
/// Direct field initializer — used to build a return value from data already in hand
/// (e.g. a just-created page) without round-tripping through `SiteContentGraph`,
/// which the file-watcher may not have indexed yet.
public init(id: String, displayName: String, route: String, siteID: String) {
    self.id = id
    self.displayName = displayName
    self.route = route
    self.siteID = siteID
}

/// Build the entity an `AddPageIntent` returns. On success the route is the created
/// identifier; on failure we return a best-effort entity from the requested input so the
/// intent keeps a single `ReturnsValue<PageEntity>` type. The dialog — not this value — is
/// the source of truth for whether creation actually succeeded.
public static func make(
    siteID: String, name: String, requestedRoute: String?, result: ContentCreateResult
) -> PageEntity {
    let route: String
    switch result {
    case .created(_, let identifier): route = identifier
    case .siteNotFound, .failed:       route = requestedRoute ?? ""
    }
    return PageEntity(id: "\(siteID):page:\(route)", displayName: name, route: route, siteID: siteID)
}
```

- [ ] **Step 4: Run the factory test to verify it passes**

Run: `swift test --package-path . --filter CreateFactory.Page`
Expected: PASS.

- [ ] **Step 5: Change `AddPageIntent.perform()` to return the entity**

In `ContentIntents.swift`, change `AddPageIntent.perform()`'s signature from
`-> some IntentResult & ProvidesDialog` to
`-> some IntentResult & ProvidesDialog & ReturnsValue<PageEntity>`,
and change the final return from
```swift
return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.created(result, kind: .page, siteName: site.displayName)))
```
to
```swift
let entity = PageEntity.make(siteID: site.id, name: name, requestedRoute: route, result: result)
return .result(value: entity,
               dialog: IntentDialog(stringLiteral: ContentDialogs.created(result, kind: .page, siteName: site.displayName)))
```
Leave the scoped/background-task branching above it unchanged.

- [ ] **Step 6: Extend the intent test to assert the returned entity (via the factory, not perform's opaque result)**

The existing `addPageForwards` / `createFailureIsHandled` tests in `ContentIntentsTests.swift` already prove `perform()` runs and forwards args. Add a dedicated factory-through-intent assertion (kept at the factory layer per the Global Constraints):

```swift
@Test("AddPage returns an entity carrying the created route")
func addPageReturnsEntity() {
    let e = PageEntity.make(
        siteID: AppIntentsTests.aSite, name: "About", requestedRoute: "/about",
        result: .created(filePath: "src/pages/about.astro", identifier: "/about"))
    #expect(e.route == "/about")
    #expect(e.id == "\(AppIntentsTests.aSite):page:/about")
}
```

- [ ] **Step 7: Add a create→preview chaining test**

Add to `Tests/AnglesiteIntentsTests/IntentChainingTests.swift` inside the `IntentChaining` suite:

```swift
// F-3 (#163): AddPageIntent returns the created PageEntity so an agent can chain
// create→preview. Reproduce by feeding the factory-built entity into PreviewSiteIntent.
@Test("add-page output flows into preview as input")
@MainActor
func addPageOutputFlowsIntoPreview() async throws {
    WindowRouter.shared.requested = nil
    let created = PageEntity.make(
        siteID: AppIntentsTests.aSite, name: "About", requestedRoute: "/about",
        result: .created(filePath: "src/pages/about.astro", identifier: "/about"))

    var preview = PreviewSiteIntent()
    preview.site = SiteEntity(TestStore.site(id: AppIntentsTests.aSite, name: "Alpha"))
    preview.page = created
    _ = try await preview.perform()

    #expect(WindowRouter.shared.requested == AppIntentsTests.aSite)
}
```

- [ ] **Step 8: Run page tests + full intents suite**

Run: `swift test --package-path . --filter AppIntentsTests`
Expected: PASS — new factory/chaining tests plus all existing `ContentIntents` tests (including `addPageForwards`, `createFailureIsHandled`, which still call `perform()` and must compile against the new return type).

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteIntents/ContentEntities.swift Sources/AnglesiteIntents/ContentIntents.swift Tests/AnglesiteIntentsTests/
git commit -m "feat(intents): F-3a — AddPageIntent returns created PageEntity (ReturnsValue) (#163)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2.2: `PostEntity` create-factory + `AddPostIntent` structured return

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift`
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift:158-201` (`AddPostIntent`)
- Test: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`, `Tests/AnglesiteIntentsTests/IntentChainingTests.swift`

**Interfaces:**
- Produces:
  - `PostEntity.init(id: String, displayName: String, slug: String, collection: String, siteID: String, isDraft: Bool, tags: [String])` — direct field init.
  - `static func PostEntity.collection(fromPath: String) -> String?` — extracts the collection segment from a post file path `"src/content/{collection}/{slug}.md"` (the path component immediately before the file). Returns `nil` if it can't parse.
  - `static func PostEntity.make(siteID: String, title: String, requestedCollection: String?, requestedSlug: String?, result: ContentCreateResult) -> PostEntity` — success: slug = identifier, collection = `collection(fromPath:) ?? requestedCollection ?? ""`, `isDraft = true`, `tags = []`; failure: slug = `requestedSlug ?? ""`, collection = `requestedCollection ?? ""`.
  - `AddPostIntent.perform()` returns `some IntentResult & ProvidesDialog & ReturnsValue<PostEntity>`.

- [ ] **Step 1: Write the failing factory + path-helper test**

Add to `ContentEntitiesTests.swift`:

```swift
@Suite("CreateFactory.Post (F-3)")
struct CreatePostFactoryTests {
    @Test("collection(fromPath:) extracts the content collection segment")
    func collectionFromPath() {
        #expect(PostEntity.collection(fromPath: "src/content/blog/hello.md") == "blog")
        #expect(PostEntity.collection(fromPath: "src/content/notes/x.md") == "notes")
        #expect(PostEntity.collection(fromPath: "weird.md") == nil)
    }

    @Test("success: slug from identifier; collection derived from filePath; draft scaffold")
    func success() {
        let e = PostEntity.make(
            siteID: AppIntentsTests.aSite, title: "Hello World",
            requestedCollection: nil, requestedSlug: nil,
            result: .created(filePath: "src/content/blog/hello-world.md", identifier: "hello-world"))
        #expect(e.slug == "hello-world")
        #expect(e.collection == "blog")
        #expect(e.isDraft == true)
        #expect(e.tags.isEmpty)
        #expect(e.id == "\(AppIntentsTests.aSite):post:hello-world")
        #expect(e.displayName == "Hello World")
    }

    @Test("success: user-supplied collection wins when filePath can't be parsed")
    func userCollectionFallback() {
        let e = PostEntity.make(
            siteID: AppIntentsTests.aSite, title: "X",
            requestedCollection: "notes", requestedSlug: nil,
            result: .created(filePath: "unparseable.md", identifier: "x"))
        #expect(e.collection == "notes")
    }

    @Test("failure: best-effort entity from requested slug/collection")
    func failure() {
        let e = PostEntity.make(
            siteID: AppIntentsTests.aSite, title: "X",
            requestedCollection: "notes", requestedSlug: "x",
            result: .failed(reason: "boom"))
        #expect(e.slug == "x")
        #expect(e.collection == "notes")
        #expect(e.id == "\(AppIntentsTests.aSite):post:x")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter CreateFactory.Post`
Expected: FAIL — `PostEntity.make` / `.collection(fromPath:)` / the direct init do not exist.

- [ ] **Step 3: Implement init + helpers in `ContentEntities.swift`**

Add to `PostEntity` (after `init(_ post:)`):

```swift
public init(id: String, displayName: String, slug: String, collection: String,
            siteID: String, isDraft: Bool, tags: [String]) {
    self.id = id
    self.displayName = displayName
    self.slug = slug
    self.collection = collection
    self.siteID = siteID
    self.isDraft = isDraft
    self.tags = tags
}

/// `"src/content/{collection}/{slug}.md"` → `"{collection}"`. The collection is the path
/// component immediately before the file. Returns nil when the path has no such parent.
public static func collection(fromPath path: String) -> String? {
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count >= 2 else { return nil }
    return parts[parts.count - 2]
}

/// Build the entity an `AddPostIntent` returns. Add Post scaffolds a *draft*, so `isDraft`
/// is true and `tags` empty. The dialog is the source of truth for success vs. failure.
public static func make(
    siteID: String, title: String, requestedCollection: String?, requestedSlug: String?,
    result: ContentCreateResult
) -> PostEntity {
    let slug: String
    let collection: String
    switch result {
    case .created(let filePath, let identifier):
        slug = identifier
        collection = Self.collection(fromPath: filePath) ?? requestedCollection ?? ""
    case .siteNotFound, .failed:
        slug = requestedSlug ?? ""
        collection = requestedCollection ?? ""
    }
    return PostEntity(id: "\(siteID):post:\(slug)", displayName: title, slug: slug,
                      collection: collection, siteID: siteID, isDraft: true, tags: [])
}
```

- [ ] **Step 4: Run the factory test to verify it passes**

Run: `swift test --package-path . --filter CreateFactory.Post`
Expected: PASS.

- [ ] **Step 5: Change `AddPostIntent.perform()` to return the entity**

In `ContentIntents.swift`, change `AddPostIntent.perform()`'s return type to
`-> some IntentResult & ProvidesDialog & ReturnsValue<PostEntity>` and the final return to:
```swift
let entity = PostEntity.make(siteID: site.id, title: title2, requestedCollection: collection,
                             requestedSlug: slug, result: result)
return .result(value: entity,
               dialog: IntentDialog(stringLiteral: ContentDialogs.created(result, kind: .post, siteName: site.displayName)))
```

- [ ] **Step 6: Add an add-post→preview-style chaining assertion**

Posts don't preview via `PreviewSiteIntent` (that takes a `PageEntity`), so the chaining check stays at the factory layer. Add to `IntentChainingTests.swift`:

```swift
// F-3 (#163): AddPostIntent returns the created PostEntity carrying slug+collection for chaining.
@Test("add-post output carries slug and collection for chaining")
func addPostOutputCarriesIdentity() {
    let e = PostEntity.make(
        siteID: AppIntentsTests.aSite, title: "Hello", requestedCollection: nil, requestedSlug: nil,
        result: .created(filePath: "src/content/blog/hello.md", identifier: "hello"))
    #expect(e.slug == "hello")
    #expect(e.collection == "blog")
    #expect(e.id == "\(AppIntentsTests.aSite):post:hello")
}
```

- [ ] **Step 7: Run post tests + full intents suite**

Run: `swift test --package-path . --filter AppIntentsTests`
Expected: PASS — new post factory/chaining tests plus existing `addPostForwards` / `createFailureIsHandled` (which call `AddPostIntent.perform()` and must compile against the new return type).

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteIntents/ContentEntities.swift Sources/AnglesiteIntents/ContentIntents.swift Tests/AnglesiteIntentsTests/
git commit -m "feat(intents): F-3b — AddPostIntent returns created PostEntity (ReturnsValue) (#163)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## PR 3 — F-2: unified `SearchContentIntent` structured return

**File structure:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift` — add `ContentKind` (`AppEnum`), `ContentSearchResultEntity` (`AppEntity`), and `ContentSearchResultEntityQuery` (`EntityQuery`).
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift:22-52` (`SearchContentIntent`) — gather entities once, return `ReturnsValue<[ContentSearchResultEntity]>`, keep the dialog.
- Modify: `docs/specs/2026-06-17-d1-intent-mcp-readiness-audit.md` — append the D.2 closeout note.
- Test: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`, `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift`.

### Task 3.1: `ContentSearchResultEntity` + query

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentEntities.swift`
- Test: `Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift`

**Interfaces:**
- Produces:
  - `enum ContentKind: String, AppEnum, Sendable { case page, post, image }` with `typeDisplayRepresentation` + `caseDisplayRepresentations`.
  - `struct ContentSearchResultEntity: AppEntity, Identifiable, Sendable` with `let id: String` and `@Property` `kind: ContentKind`, `title: String`, `locator: String`, `siteID: String`; plus three convenience initializers `init(page:)`, `init(post:)`, `init(image:)` mapping the typed entities into a flattened result (`locator` = `route` / `"{collection}/{slug}"` / `relativePath`).
  - `struct ContentSearchResultEntityQuery: EntityQuery` whose `entities(for:)` parses the kind token from each id (`"{siteID}:{kind}:{rest}"`) and delegates to `SiteContentGraph.pages(ids:)` / `.posts(ids:)` / `.images(ids:)`, mapping hits back into `ContentSearchResultEntity`.

- [ ] **Step 1: Write the failing test**

Add to `ContentEntitiesTests.swift`:

```swift
@Suite("ContentSearchResultEntity (F-2)")
struct SearchResultEntityTests {
    @Test("maps each typed entity into a flattened result with kind + locator")
    func mapping() {
        let p = ContentSearchResultEntity(page: PageEntity(AppIntentsTests.gPage(route: "/about", title: "About")))
        #expect(p.kind == .page)
        #expect(p.title == "About")
        #expect(p.locator == "/about")
        #expect(p.id == "\(AppIntentsTests.aSite):page:/about")

        let o = ContentSearchResultEntity(post: PostEntity(AppIntentsTests.gPost(slug: "hi", collection: "blog", title: "Hi")))
        #expect(o.kind == .post)
        #expect(o.locator == "blog/hi")
        #expect(o.id == "\(AppIntentsTests.aSite):post:hi")

        let i = ContentSearchResultEntity(image: ImageEntity(AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg")))
        #expect(i.kind == .image)
        #expect(i.title == "hero.jpg")
        #expect(i.locator == "public/images/hero.jpg")
    }

    @Test("query resolves ids back through the graph by kind")
    func queryRoundTrip() async throws {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: AppIntentsTests.aSite,
            pages: [AppIntentsTests.gPage(route: "/about", title: "About")],
            posts: [AppIntentsTests.gPost(slug: "hi", collection: "blog", title: "Hi")],
            images: [])
        try await ContentGraphOverride.$scoped.withValue(graph) {
            let results = try await ContentSearchResultEntityQuery().entities(
                for: ["\(AppIntentsTests.aSite):page:/about", "\(AppIntentsTests.aSite):post:hi"])
            #expect(results.count == 2)
            #expect(results.contains { $0.kind == .page && $0.locator == "/about" })
            #expect(results.contains { $0.kind == .post && $0.locator == "blog/hi" })
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter ContentSearchResultEntity`
Expected: FAIL — the new types don't exist (compile error).

- [ ] **Step 3: Implement the enum, entity, and query in `ContentEntities.swift`**

Append a new `MARK` section:

```swift
// MARK: - ContentSearchResultEntity (F-2)

/// Discriminator for the flattened search result. `SearchContentIntent` spans three entity
/// types; `ReturnsValue<T>` needs one concrete type, so results carry their kind.
public enum ContentKind: String, AppEnum, Sendable {
    case page, post, image
    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Content Kind" }
    public static var caseDisplayRepresentations: [ContentKind: DisplayRepresentation] {
        [.page: "Page", .post: "Post", .image: "Image"]
    }
}

/// A single search hit, flattened across pages/posts/images. `id` is the *underlying* entity id
/// (e.g. "s1:page:/about"), so an agent can re-resolve the typed entity (PageEntity, …) to chain.
public struct ContentSearchResultEntity: AppEntity, Identifiable, Sendable {
    public let id: String
    @Property(title: "Kind")    public var kind: ContentKind
    @Property(title: "Title")   public var title: String
    @Property(title: "Locator") public var locator: String
    @Property(title: "Site ID") public var siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Search Result" }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(locator)")
    }
    public static let defaultQuery = ContentSearchResultEntityQuery()

    public init(id: String, kind: ContentKind, title: String, locator: String, siteID: String) {
        self.id = id; self.kind = kind; self.title = title; self.locator = locator; self.siteID = siteID
    }
    public init(page e: PageEntity) {
        self.init(id: e.id, kind: .page, title: e.displayName, locator: e.route, siteID: e.siteID)
    }
    public init(post e: PostEntity) {
        self.init(id: e.id, kind: .post, title: e.displayName, locator: "\(e.collection)/\(e.slug)", siteID: e.siteID)
    }
    public init(image e: ImageEntity) {
        self.init(id: e.id, kind: .image, title: e.displayName, locator: e.relativePath, siteID: e.siteID)
    }
}

/// Re-resolves flattened results by parsing the kind token out of each id and delegating to the
/// graph's typed id lookups. Plain `EntityQuery` (not `EntityStringQuery`): string search lives on
/// the typed entity queries and on `SearchContentIntent` itself; this only needs id round-trip.
public struct ContentSearchResultEntityQuery: EntityQuery {
    @Dependency private var graph: SiteContentGraph
    public init() {}
    private var resolved: SiteContentGraph { ContentGraphOverride.scoped ?? graph }

    public func entities(for identifiers: [String]) async throws -> [ContentSearchResultEntity] {
        let g = resolved
        var pageIDs: [String] = [], postIDs: [String] = [], imageIDs: [String] = []
        for id in identifiers {
            // id == "{siteID}:{kind}:{rest}". The siteID is a filesystem path (no ":"), so splitting
            // on ":" with maxSplits 2 yields exactly [siteID, kind, rest]; parts[1] is the kind.
            let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            switch parts[1] {
            case "page": pageIDs.append(id)
            case "post": postIDs.append(id)
            case "image": imageIDs.append(id)
            default: continue
            }
        }
        async let pages = g.pages(ids: pageIDs)
        async let posts = g.posts(ids: postIDs)
        async let images = g.images(ids: imageIDs)
        let mapped = await (pages.map { ContentSearchResultEntity(page: PageEntity($0)) }
            + posts.map { ContentSearchResultEntity(post: PostEntity($0)) }
            + images.map { ContentSearchResultEntity(image: ImageEntity($0)) })
        // Preserve caller's id order.
        let order = Dictionary(uniqueKeysWithValues: identifiers.enumerated().map { ($1, $0) })
        return mapped.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }
}
```

> **Implementer note on id parsing:** a site id like `/Users/x/Sites/alpha` contains `/` but no `:`. The entity id is `"{siteID}:{kind}:{rest}"`. Splitting on `:` with `maxSplits: 2` yields exactly `[siteID, kind, rest]` — `parts[1]` is the kind. Verify with the `queryRoundTrip` test (the fixture siteID has no `:`).

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter ContentSearchResultEntity`
Expected: PASS — both mapping and query round-trip.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/ContentEntities.swift Tests/AnglesiteIntentsTests/ContentEntitiesTests.swift
git commit -m "feat(intents): F-2a — ContentSearchResultEntity flattened search result + query (#163)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3.2: `SearchContentIntent` returns the flattened results

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift:22-52`
- Test: `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift`

**Interfaces:**
- Consumes: `ContentSearchResultEntity` (Task 3.1), `SiteContentGraph.searchPages/Posts/Images`.
- Produces: `static func SearchContentIntent.results(graph:siteID:query:) async -> (dialog: String, items: [ContentSearchResultEntity])` — gathers matches once and returns both the (frozen-wording) dialog and the flattened, deterministically-sorted results. `perform()` returns `some IntentResult & ProvidesDialog & ReturnsValue<[ContentSearchResultEntity]>`.

- [ ] **Step 1: Write the failing test**

Add to `ContentIntentsTests.swift`:

```swift
@Test("SearchContentIntent.results returns dialog parity + flattened typed results")
func searchResults() async {
    let graph = SiteContentGraph()
    await graph.load(
        siteID: AppIntentsTests.aSite,
        pages: [AppIntentsTests.gPage(route: "/about", title: "About")],
        posts: [AppIntentsTests.gPost(slug: "about-us", title: "About Us")],
        images: [])
    let (dialog, items) = await SearchContentIntent.results(graph: graph, siteID: AppIntentsTests.aSite, query: "about")
    #expect(dialog == "Found 1 page and 1 post matching “about”.")   // byte-identical to before
    #expect(items.count == 2)
    #expect(items.contains { $0.kind == .page && $0.locator == "/about" })
    #expect(items.contains { $0.kind == .post && $0.locator == "blog/about-us" })
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter searchResults`
Expected: FAIL — `SearchContentIntent.results(...)` doesn't exist.

- [ ] **Step 3: Refactor `SearchContentIntent` in `ContentIntents.swift`**

Replace the existing `dialog(...)` helper and `perform()` with:

```swift
public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[ContentSearchResultEntity]> {
    let (dialog, items) = await Self.results(graph: ContentGraphOverride.scoped ?? graph, siteID: site.id, query: query)
    return .result(value: items, dialog: IntentDialog(stringLiteral: dialog))
}

/// Gather matches once and build both the spoken dialog (unchanged wording) and the flattened
/// typed results. Static + graph-injected so it's unit-testable without the AppIntents runtime.
static func results(graph: SiteContentGraph, siteID: String, query: String) async -> (dialog: String, items: [ContentSearchResultEntity]) {
    let pages = await graph.searchPages(siteID: siteID, matching: query)
    let posts = await graph.searchPosts(siteID: siteID, matching: query)
    let images = await graph.searchImages(siteID: siteID, matching: query)
    let dialog = ContentDialogs.search(query: query, pageCount: pages.count, postCount: posts.count, imageCount: images.count)
    let items = pages.map { ContentSearchResultEntity(page: PageEntity($0)) }
        + posts.map { ContentSearchResultEntity(post: PostEntity($0)) }
        + images.map { ContentSearchResultEntity(image: ImageEntity($0)) }
    return (dialog, items)
}
```

> Note: the old `static func dialog(...)` is removed. The existing `searchHelper` test in `ContentIntentsTests.swift` calls `SearchContentIntent.dialog(...)` — update it to call `SearchContentIntent.results(...).dialog` so it keeps asserting dialog parity. (`SiteStatusIntent.dialog(...)` is untouched.)

- [ ] **Step 4: Update the existing `searchHelper` test to the new API**

In `ContentIntentsTests.swift`, change the body of `searchHelper()` from
`let dialog = await SearchContentIntent.dialog(graph: graph, siteID: AppIntentsTests.aSite, query: "about")`
to
`let dialog = await SearchContentIntent.results(graph: graph, siteID: AppIntentsTests.aSite, query: "about").dialog`
(leave the `#expect(dialog == ...)` assertion unchanged — wording is frozen).

- [ ] **Step 5: Run search tests + full intents suite**

Run: `swift test --package-path . --filter AppIntentsTests`
Expected: PASS — `searchResults`, the updated `searchHelper`, and every other intents suite.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteIntents/ContentIntents.swift Tests/AnglesiteIntentsTests/ContentIntentsTests.swift
git commit -m "feat(intents): F-2b — SearchContentIntent returns flattened ContentSearchResultEntity list (#163)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3.3: D.2 closeout — descriptor decision + full-suite verification

**Files:**
- Modify: `docs/specs/2026-06-17-d1-intent-mcp-readiness-audit.md`

- [ ] **Step 1: Append the closeout note to the D.1 audit doc**

Add this section to the end of `docs/specs/2026-06-17-d1-intent-mcp-readiness-audit.md`:

```markdown
## D.2 Closeout (2026-06-17) — descriptor decision

With F-1/F-2/F-3 landed, the two D.2 candidate descriptors are resolved:

- **`anglesite_list_content` — not needed.** The enriched `SearchContentIntent` (now returns a
  typed `[ContentSearchResultEntity]`) plus `SiteStatusIntent` cover structured content
  enumeration via auto-derived tools. No hand-registered descriptor.
- **`anglesite_apply_edit` — deliberately not exposed** as a system-wide intent. It is a low-level
  `selector / op / value` primitive, not a natural-language action; exposing a structured DOM-edit
  primitive to arbitrary external agents without the edit overlay's live selection context is a
  safety regression. It stays on the app-internal MCP path (`MCPClient` + `AnglesiteBridge`);
  `EditContentIntent`'s natural-language `instruction` form remains the agent-facing edit surface.

No `AnglesiteMCPRegistration` / hand-written descriptors are required: the auto-derived tools from
the enriched intents *are* D.2's "custom MCP tool descriptors". Closes #163.
```

- [ ] **Step 2: Full-suite verification**

Run: `swift test --package-path . 2>&1 | tail -40`
Expected: all `AnglesiteIntents`, `AnglesiteCore`, `AnglesiteBridge` suites PASS; only the two plugin-path e2e tests (`MCPClientHTTPEndToEndTests`, `AppliesEditEndToEndTests`) fail when the sibling plugin checkout is absent (known #222). Confirm the intents test count grew by the tests added across F-1/F-2/F-3.

- [ ] **Step 3: Commit**

```bash
git add docs/specs/2026-06-17-d1-intent-mcp-readiness-audit.md
git commit -m "docs(intents): D.2 closeout — no custom MCP descriptors needed; close #163

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (completed during planning)

- **Spec coverage:** F-1 → Task 1.1; F-3 → Tasks 2.1 (page) + 2.2 (post); F-2 → Tasks 3.1 (entity+query) + 3.2 (intent); closeout decision → Task 3.3. All four spec deliverables map to tasks.
- **Type consistency:** `PageEntity.make` / `PostEntity.make` / `ContentSearchResultEntity` initializers, `ContentSearchResultEntityQuery.entities(for:)`, and `SearchContentIntent.results(...)` signatures are referenced identically across the tasks that define and consume them.
- **Frozen wording:** the only dialog touched is via `ContentDialogs.search` (unchanged); the `searchHelper` test is migrated to `.results(...).dialog` but keeps its exact-string assertion.
- **Known-baseline failures** (#222 e2e) are called out so they aren't mistaken for regressions.

## Out of scope (per spec)

- Device-level donated-Shortcut persistence smoke after the F-1 schema bump (manual; PR follow-up).
- Any `AnglesiteMCPRegistration` descriptor surface (decided against).
- Phase D D.3/D.4/D.5 (#164/#165/#166) — separate work consuming this schema.
```
