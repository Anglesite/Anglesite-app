# D.2 — Intent Schema Enrichment for Auto-Derived MCP Tools

**Issue:** [#163](https://github.com/Anglesite/Anglesite-app/issues/163) (parent [#135](https://github.com/Anglesite/Anglesite-app/issues/135), Phase D — System-wide MCP exposure)
**Date:** 2026-06-17
**Predecessor:** [`docs/specs/2026-06-17-d1-intent-mcp-readiness-audit.md`](./2026-06-17-d1-intent-mcp-readiness-audit.md) (D.1 audit — defines findings F-1/F-2/F-3)

## Framing — why this is *not* "write custom MCP descriptors"

macOS 27's platform `mcpbridge` **auto-derives MCP tool schemas from App Intent / `AppEntity`
schema metadata** — `@Parameter` titles/descriptions, `@Property`-annotated entity fields, and
`ReturnsValue<T>` return types. The D.1 audit established that the right way to satisfy D.2's
"custom MCP tool descriptors for rich operations" is to make the *existing* intent/entity schema
rich enough that the auto-derived tools are usable by a headless agent — and only then decide
whether the two candidate hand-written descriptors (`anglesite_apply_edit`,
`anglesite_list_content`) are still needed.

D.1 already landed the small, schema-safe half (`@Parameter(description:)` on free-form strings;
`ReturnsValue<SiteEntity>` on Deploy/Backup). This spec covers the three deliberate
schema/structural follow-ups the audit scoped out (F-1, F-2, F-3) plus the closeout decision.

## Scope

Three stacked PRs into `main`, in dependency order, then a docs-only closeout:

1. **F-1** — promote entity disambiguating fields to `@Property`.
2. **F-3** — create intents return the created entity (`ReturnsValue<PageEntity>` / `<PostEntity>`).
3. **F-2** — `SearchContentIntent` returns a unified structured result list.
4. **Closeout** — document the `anglesite_apply_edit` / `anglesite_list_content` decision; close #163.

Ordering rationale: F-1 enriches the *same* `PageEntity`/`PostEntity` that F-3 then returns —
without `@Property` fields the entity F-3 hands back is near-opaque to an agent — so F-1 is
foundational and lands first. F-2 introduces a new entity type and is independent, sequenced last.

## F-1 — `@Property` promotion *(PR 1)*

**File:** `Sources/AnglesiteIntents/ContentEntities.swift`

Promote these from plain `let` to `@Property` so an agent receives them as **typed, extractable**
schema fields rather than only as a `displayRepresentation` subtitle string:

| Entity | Promote to `@Property` |
|---|---|
| `PageEntity` | `route`, `siteID` |
| `PostEntity` | `slug`, `collection`, `siteID` |
| `ImageEntity` | `relativePath`, `siteID` |

**Each `@Property` carries a `title:`** (e.g. `@Property(title: "Route")`) so the derived schema
field is self-describing.

### Schema-stability handling

The `ImageEntity.usedOnPages` comment deliberately kept fields out of the schema to avoid "a
source-breaking `AppEntity` schema change for Shortcuts persistence / donated interactions." This
change respects that constraint by being **strictly additive**:

- No field is renamed or removed.
- `id`, `displayName`, and `displayRepresentation` are untouched — already-donated interactions
  resolve by `id`, which does not change.
- `usedOnPages` stays a plain `let` (still intentionally out of the schema).
- The existing memberwise-style `init(_ page:)` / `init(_ post:)` / `init(_ image:)` initializers
  are unchanged in signature; `@Property` fields are assigned the same way (a `@Property` is still
  a stored property and is set in `init`).

Additive `@Property` is the documented-safe direction. The **residual manual verification** —
that a previously-donated Shortcut still resolves after the schema bump — is a device-level check
recorded in the PR as a follow-up smoke, not something the unit suite can cover.

### Tests (F-1)

- Existing `ContentEntities`/query tests must stay green (no behavior change to `id`, search,
  resolution).
- Add assertions that the promoted fields are readable on a constructed entity (guards against an
  init regression). The fields were already public `let`s, so this is mostly a compile-surface and
  value-fidelity check.

## F-3 — create intents return the created entity *(PR 2)*

**Files:** `Sources/AnglesiteIntents/ContentIntents.swift`, `Sources/AnglesiteIntents/ContentEntities.swift`

Mirror D.1's Deploy/Backup pattern:

- `AddPageIntent.perform()` → `some IntentResult & ProvidesDialog & ReturnsValue<PageEntity>`
- `AddPostIntent.perform()` → `some IntentResult & ProvidesDialog & ReturnsValue<PostEntity>`

### Reconstruction approach — construct from known fields, do **not** re-read the graph

`ContentCreateResult.created(filePath:identifier:)` gives back the route (page) or slug (post)
and the relative file path. The intent already knows `site.id`, and the user-supplied `name`
(page title) / `title` (post title). Re-reading `SiteContentGraph` to fetch the just-created entity
**races the file-watcher** that populates the graph — the new file may not be indexed yet.

Instead, add a **direct field-based initializer** to each entity and build the return value from
data already in hand:

```swift
// PageEntity
public init(id: String, displayName: String, route: String, siteID: String) { ... }
// PostEntity — collection/slug/draft/tags known at creation; tags = [] for a fresh draft
public init(id: String, displayName: String, slug: String, collection: String,
            siteID: String, isDraft: Bool, tags: [String]) { ... }
```

The `id` is reconstructed with the same formula the graph uses (`"{siteID}:page:{route}"` /
`"{siteID}:post:{slug}"`) so the returned entity round-trips through the entity query later. For a
post, `collection` falls back to the same default the create path used when the user omitted it;
`isDraft = true` (Add Post scaffolds a draft), `tags = []`.

### Failure paths

AppIntents requires a **single** return type per `perform()`, so once the success type is
`ReturnsValue<PageEntity>` *every* branch must return a value. This mirrors `SiteIntents` Deploy,
which returns `value: site` even on its "couldn't find" branch.

Decision: **always return a value.** On success, return the entity reconstructed from
`ContentCreateResult.created`. On `.siteNotFound` / `.failed`, reconstruct a **best-effort entity
from the requested input** (`site.id` + the requested `route`/`name` for a page, `slug`/`title`
for a post) and pair it with the failure dialog. The **dialog is the source of truth** for whether
creation succeeded — an agent that chains on the returned entity after a failure is acting against
the dialog, exactly as it would by chaining on Deploy's returned site after a failed deploy. Keep
this caveat in a code comment so the asymmetry (value present, dialog says failed) is explicit.

### Tests (F-3)

- Extend the existing `ContentOperationsOverride`-scoped Add Page/Add Post tests to assert the
  returned entity's `id`, `route`/`slug`, and `siteID` match the created identifier (the fakes
  already drive `ContentCreateResult`).
- Add a chaining-style test in the `IntentChainingTests` idiom: Add Page → reconstruct the entity
  → assert it carries the route an agent would pipe into `PreviewSiteIntent`.

## F-2 — `SearchContentIntent` unified structured return *(PR 3)*

**Files:** `Sources/AnglesiteIntents/ContentEntities.swift` (new entity + query),
`Sources/AnglesiteIntents/ContentIntents.swift` (intent return type)

### New entity: `ContentSearchResultEntity`

`ReturnsValue<T>` takes a single concrete type, but search spans three entity types. Flatten them
into one entity with a `kind` discriminator (the standard AppIntents answer to "no union return"):

```swift
public struct ContentSearchResultEntity: AppEntity, Identifiable, Sendable {
    public let id: String          // the underlying entity id, e.g. "s1:page:/about"
    @Property(title: "Kind")    public var kind: ContentKind   // page | post | image (AppEnum)
    @Property(title: "Title")   public var title: String       // displayName of the underlying entity
    @Property(title: "Locator") public var locator: String     // route | "collection/slug" | relativePath
    @Property(title: "Site ID") public var siteID: String
    // typeDisplayRepresentation "Search Result"; displayRepresentation title: title, subtitle: locator
}

public enum ContentKind: String, AppEnum { case page, post, image /* + CaseDisplayRepresentations */ }
```

The `id` **is** the underlying entity id, so it is lossless for re-resolution: an agent can take a
`kind == .page` result and resolve the matching `PageEntity` (via `PageEntityQuery.entities(for:)`)
to pipe into `PreviewSiteIntent`.

### Query

`ContentSearchResultEntity` needs an `EntityQuery` (AppEntity requirement). `entities(for:)` parses
the `kind` token out of each id (`"{siteID}:{kind}:{locator}"`), groups ids by kind, and delegates
to the existing graph lookups (`pages(ids:)` / `posts(ids:)` / `images(ids:)`), mapping each hit
into a `ContentSearchResultEntity`. No `EntityStringQuery` (string search lives on the typed entity
queries and on the intent itself) — a plain `EntityQuery` is sufficient for id round-trip.

### Intent change

`SearchContentIntent.perform()` →
`some IntentResult & ProvidesDialog & ReturnsValue<[ContentSearchResultEntity]>`.

The existing `static func dialog(...)` already gathers `pages`/`posts`/`images`. Refactor the
gather step so `perform()` reuses the matched entities to build *both* the spoken count dialog
(unchanged wording) **and** the flattened result array. Sort the combined results deterministically
(reuse the lastModified-desc, id-asc ordering the entity queries use) so the returned list is stable.

### Tests (F-2)

- Pure mapping test: given known graph fixtures, `searchContent` produces the expected flattened
  `[ContentSearchResultEntity]` with correct `kind`/`id`/`locator` per type.
- Dialog parity: the spoken count string is byte-identical to today's `ContentDialogs.search(...)`.
- Query round-trip: `ContentSearchResultEntity` ids resolve back through the new `EntityQuery`.

## D.2 Closeout — the descriptor decision *(docs-only PR / folded into PR 3)*

Update `docs/specs/2026-06-17-d1-intent-mcp-readiness-audit.md` (or append a short D.2 closeout
note there) recording the resolution of the two D.2 candidate descriptors:

- **`anglesite_list_content` — not needed.** The enriched `SearchContentIntent` (typed result
  list) plus `SiteStatusIntent` cover structured content enumeration. No separate descriptor.
- **`anglesite_apply_edit` — deliberately not exposed** as a system-wide intent. It is a low-level
  `selector / op / value` primitive, not a natural-language action. Handing an arbitrary external
  agent a structured DOM-edit primitive *without the edit overlay's live selection context* is a
  safety regression (no human-in-the-loop targeting). It stays on the **app-internal** MCP path
  (`MCPClient` + `AnglesiteBridge`). `EditContentIntent`'s natural-language `instruction` form
  remains the agent-facing edit surface.

With both candidates resolved, #163 closes: the auto-derived tools from the enriched intents are
the "custom MCP tool descriptors," and no hand-registered `AnglesiteMCPRegistration` descriptors
are required.

## Out of scope

- Device-level donated-Shortcut persistence verification after the F-1 schema bump (manual smoke,
  tracked as a PR follow-up).
- Any `AnglesiteMCPRegistration` / hand-written descriptor surface (explicitly decided against).
- The `SiteEntityQuery` empty-string "list all" inconsistency (D.1 recorded it as intentional;
  unchanged).
- Phase D's remaining sub-issues (D.3 bootstrap wiring #164, D.4 security smoke #165, D.5 CLI smoke
  #166) — separate work that consumes the schema this spec produces.

## Testing summary

All changes live in `AnglesiteIntents`, fully covered by the Swift Testing suite via the existing
`ContentGraphOverride` / `ContentOperationsOverride` seams — no AppIntents runtime, no hosted app
target, so it runs on CI. Target: `AnglesiteIntents` suite stays green and grows by the per-PR
tests above. Full suite parity otherwise unchanged (the known #222 plugin-path e2e tests are
unrelated).
