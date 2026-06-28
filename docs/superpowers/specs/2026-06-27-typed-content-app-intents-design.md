# V-1.9 / #351 — App-Intent entities for typed content

**Status:** approved (2026-06-27)
**Issue:** [#351](https://github.com/Anglesite/Anglesite-app/issues/351) — part of #335 (V-1), plan task 1.9.
**Branch / worktree:** `feat/351-typed-content-intents` → `.claude/worktrees/351-typed-content-intents`

## Goal

Make the new typed content objects (V-1.2 personal types + V-1.3 business types)
matchable by Siri/Spotlight, and add a typed filter intent so a user can ask for
content *of a given type* (e.g. "find my events"). Acceptance from the issue: new
types are matchable by voice/Spotlight; intent tests added.

## Background / current state

The typed content objects are declared once as `ContentTypeDescriptor`s in
`AnglesiteCore/ContentTypeRegistry.swift` (V-1.1). Ten of them are
`.collection(...)`-stored:

| Type id | Collection | Type id | Collection |
|---|---|---|---|
| note | notes | bookmark | bookmarks |
| article | articles | reply | replies |
| photo | photos | like | likes |
| album | albums | announcement | announcements |
| | | event | events |
| | | review | reviews |

`businessProfile` is the one `.page`-stored type and is **out of scope** here.

Two facts established during design that shape the approach:

1. **The collection-backed types already flow through as `SiteContentGraph.Post`s.**
   `ContentScanner` scans every built-in collection
   (`ContentTypeRegistry.builtIns.compactMap(\.collection)`), so notes, articles,
   events, reviews, … are already populated into the graph as `Post`s — already
   resolvable as `PostEntity` and already Spotlight-indexed by
   `ContentSpotlightIndexer` (via `indexPosts`).

2. **What's missing is a typed dimension.** A `Post` carries its `collection`
   ("events") but not its content *type* ("event"). Siri/Spotlight sees every
   entry as a generic "Post", and `ContentMatchKind` only knows `page/post/image`.

Because each type maps 1:1 to a collection, **content-type identity is a pure
function of `Post.collection` via the registry** — no changes to
`SiteContentGraph`, `ContentScanner`, the MCP `list_content` path, or the Spotlight
indexer are required.

## Approach (chosen)

Enrich the existing post entity with a typed property and add a typed filter
intent. Rejected alternatives:

- **Per-type `AppEntity` (`NoteEntity`/`EventEntity`/…)** — ~10 near-identical
  entity + query types, schema explosion, and the graph doesn't model per-type
  fields. Boilerplate with no payoff. Rejected.
- **Touching the graph / scanner to store `contentType`** — unnecessary; the value
  derives from `collection`, and there are two population paths (native scanner +
  MCP `list_content` DTO) that would both need it. Deriving keeps a single source
  of truth. Rejected.

## Components

### 1. `AnglesiteCore` — registry reverse lookup (pure)

Add to `ContentTypeRegistry`:

- `func descriptor(forCollection collection: String) -> ContentTypeDescriptor?`
  — reverse of the existing `descriptor(id:)`, backed by a precomputed
  `[collection: id]` map so lookups are O(1).
- A shared default instance (e.g. `static let `default` = ContentTypeRegistry()`)
  so the entity layer can resolve types without rebuilding the registry per call.

This is the only `AnglesiteCore` change — pure value data, no I/O, fully
unit-testable.

### 2. `PostEntity` — typed property (`AnglesiteIntents/ContentEntities.swift`)

Add `@Property(title: "Type") public var contentType: String`, derived in
`init(_ post:)` from `post.collection`:

- known collection → the descriptor's `displayName` (e.g. "Event")
- unknown / custom collection (e.g. a hand-rolled "blog") → fall back to the raw
  collection string, so nothing is lost.

Threaded through the secondary memberwise `init` as well (with a default so call
sites that don't care are unaffected). `PostEntity` is already an `IndexedEntity`,
so the new `@Property` flows into the Spotlight `CSSearchableItemAttributeSet`
automatically **and** appears in the auto-derived Shortcuts/MCP schema — **no
`ContentSpotlightIndexer` change required.**

`ContentMatchEntity` is left unchanged (its `kind` remains the coarse
storage-kind: page/post/image). The typed dimension lives on `PostEntity`.

### 3. `ContentTypeAppEnum` (new file in `AnglesiteIntents`)

An `AppEnum` whose cases mirror the ten collection-backed built-in type ids, each
with a `DisplayRepresentation`. It is the typed parameter for the filter intent and
maps to/from the registry id. Kept honest by a **drift-guard test** (see Testing) —
the same convention V-1.3 used for the content-config drift guard — so introducing
a new built-in collection type fails the test until the enum is updated.

### 4. `FindContentByTypeIntent` (`AnglesiteIntents/ContentIntents.swift`)

- Parameters: `site: SiteEntity`, `contentType: ContentTypeAppEnum`.
- `perform()` resolves the type's collection from the registry, filters
  `graph.posts(for: site.id)` by it, and returns `[PostEntity]` sorted by the
  standard `(lastModified desc, id asc)` comparator the other queries use.
- Returns `[PostEntity]` (homogeneous — every result is a post), not
  `ContentMatchEntity`.
- Logic in a static, graph-injected helper
  `matches(graph:siteID:type:) -> [PostEntity]`, mirroring
  `SearchContentIntent.matches`, so it's unit-testable without the AppIntents
  runtime via the `ContentGraphOverride.scoped` seam.
- A spoken-result dialog string is added to `ContentDialogs`
  (pure/unit-testable, like the others).
- **Not** registered as a curated `AppShortcut`: `AnglesiteShortcuts` is at its
  10-phrase Siri budget. The intent is still discoverable in the Shortcuts app and
  via entity matching; voice/Spotlight matching of the typed content is carried by
  the `PostEntity.contentType` property.

## Data flow

```
ContentTypeRegistry (id ↔ collection)         ← single source of truth
        │  descriptor(forCollection:)
        ▼
SiteContentGraph.Post (collection)            ← unchanged; already populated
        │
        ├─ PostEntity.init(_:)  → contentType (display)   → Spotlight + Siri match
        │
        └─ FindContentByTypeIntent.matches(graph,site,type)
               filter posts by registry collection(type)  → [PostEntity]
```

## Testing

- **`ContentEntitiesTests`** — `PostEntity` derives `contentType` from a known
  collection (display name); unknown collection falls back to the raw collection
  string.
- **`FindContentByTypeIntentTests`** (new) — type-filtered results contain only the
  requested type; sort order is `(lastModified desc, id asc)`; empty result when no
  posts of that type; exercised through `ContentGraphOverride.scoped`.
- **`ContentTypeAppEnumTests`** (new) — drift guard: enum case ids equal the
  registry's collection-backed type ids; every case has a non-empty
  `DisplayRepresentation`.
- **`ContentDialogsTests`** — the new filter dialog string (count phrasing, empty
  case).
- **Schema/smoke sweep** — update `SchemaConformanceTests` / `SmokeMatrixTests` if
  they enumerate the intent/entity surface, so the new intent + enum are covered.

## Out of scope

- `businessProfile` / page-singleton entity surfacing → follows #388.
- Per-type `AppEntity` types.
- `SiteContentGraph` / `ContentScanner` / MCP `list_content` changes.
- New curated Siri phrases (10-phrase budget is full).
