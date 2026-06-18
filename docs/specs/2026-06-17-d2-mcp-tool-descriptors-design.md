# D.2 — MCP Tool Descriptors (Intent Schema Enrichment)

**Issue:** [#163](https://github.com/Anglesite/Anglesite-app/issues/163) (parent [#135](https://github.com/Anglesite/Anglesite-app/issues/135), Phase D — System-wide MCP exposure)
**Date:** 2026-06-17
**Depends on:** D.1 audit ([#162](https://github.com/Anglesite/Anglesite-app/issues/162), merged in #225) — [`docs/specs/2026-06-17-d1-intent-mcp-readiness-audit.md`](../../specs/2026-06-17-d1-intent-mcp-readiness-audit.md)
**Spec:** [`docs/superpowers/specs/2026-06-11-siri-ai-integration-design.md`](2026-06-11-siri-ai-integration-design.md) — Phase D

## Why this is not what #163 originally asked for

#163 was written assuming we would hand-write custom MCP tool descriptors
(`anglesite_apply_edit`, `anglesite_list_content`) via an `AnglesiteMCPRegistration`
type. The D.1 audit determined the premise no longer holds: macOS 27's platform
`mcpbridge` **auto-derives** MCP tool schemas from App Intent / `AppEntity` schema
metadata (`@Parameter` titles/descriptions, `@Property`-annotated entity fields,
`ReturnsValue<T>` return types). So the high-value work is not a parallel hand-written
MCP surface that could drift — it is enriching the *existing* intent/entity schema so the
auto-derived tools become usable by an agent with no human in the loop. That enrichment
serves Siri, Shortcuts, and MCP simultaneously.

**Decision:** D.2 implements the three schema-enrichment follow-ups the D.1 audit scoped
(F-1, F-2, F-3) and **defers custom descriptors as YAGNI** until the D.5 manual smoke
([#166](https://github.com/Anglesite/Anglesite-app/issues/166)) proves a concrete gap the
bridge cannot fill. This closes #163.

## Structural fact the whole design leans on

Entity identity is the **`id`**, not the property bag. AppIntents re-resolves a persisted
or donated entity by handing its `id` back to `EntityQuery.entities(for:)`, which re-reads
the live `SiteContentGraph`. Two consequences:

1. **F-1 is safe:** adding `@Property` annotations to fields that are already populated is
   schema-*additive*; persisted Shortcuts/donations restore via `id`, not a stored
   property snapshot, so they survive the schema growth.
2. **F-2's wrapper is cheap:** `ContentMatchEntity` can be a throwaway projection whose
   `id` is the real underlying entity's id (`"{siteID}:{kind}:{path}"`), so an agent can
   hand a match straight to any intent that resolves the concrete type.

## F-1 — Promote entity fields to `@Property`

Change the audit-named fields from plain `let` to `@Property(title:) var` so they enter
the derived schema as typed, extractable values an agent can pipe into a follow-up call.

| Entity | Promote to `@Property` |
|---|---|
| `PageEntity` | `route`, `siteID` |
| `PostEntity` | `slug`, `collection`, `siteID` |
| `ImageEntity` | `relativePath`, `siteID` |

- `id` stays the plain entity identifier (AppEntity identity, not a `@Property`).
- `displayName` stays surfaced via `displayRepresentation` (title); not separately promoted.
- **Deliberately out of scope:** `usedOnPages` (the `ImageEntity` comment already flags it
  as a source-breaking schema change), `isDraft`, `tags`. Keeping them out minimizes
  schema churn; revisit only if D.5 shows an agent needs them.

### Risk + de-risk

The documented risk is Shortcuts persistence of already-donated interactions across the
schema bump. Per the structural fact above, re-resolution is by `id`, so the change is
additive. Verification gate for this PR:

- Build **both** schemes via `xcodebuild` (`Anglesite` + `AnglesiteMAS`) — not just
  `swift test` — to prove the `.app` targets link with the schema change.
- Run the `AnglesiteIntents` suite green.
- Add a manual Shortcuts-persistence check to the D.5 ([#166](https://github.com/Anglesite/Anglesite-app/issues/166))
  smoke checklist (donate an interaction → confirm it still resolves after the bump).
  **Not a blocker for this PR** — it needs a real device/Shortcuts surface.

## F-2 — `ContentMatchEntity` + `SearchContentIntent` structured return

`SearchContentIntent` matches three entity types but `ReturnsValue<T>` is single-typed, so
we return a uniform projection.

```swift
enum ContentMatchKind: String, AppEnum {     // typed in the derived schema
    case page, post, image
}

struct ContentMatchEntity: AppEntity, Identifiable, Sendable {
    let id: String                 // reuses underlying "{siteID}:{kind}:{path}" — already unique
    @Property(title: "Kind")  var kind: ContentMatchKind
    @Property(title: "Title") var title: String
    @Property(title: "Path")  var path: String     // route | slug | relativePath
    @Property(title: "Site")  var siteID: String
    // displayRepresentation: title + subtitle "\(kind): \(path)"
}

struct ContentMatchEntityQuery: EntityQuery {
    // entities(for:) parses the ":page:" / ":post:" / ":image:" segment from each id
    // and delegates to the existing Page/Post/Image sub-query, then projects to a match.
}
```

`SearchContentIntent.perform` gains `& ReturnsValue<[ContentMatchEntity]>`, returning the
flattened matches (pages, then posts, then images) **and** keeping today's spoken count
dialog unchanged. The pure `ContentDialogs.search(...)` formatter is untouched.

## F-3 — Structured return from create intents

`AddPageIntent` → `& ReturnsValue<PageEntity?>`, `AddPostIntent` → `& ReturnsValue<PostEntity?>`.

- **Success** (`.created(filePath, identifier)`): reconstruct the entity from inputs +
  result. `identifier` is the route (page) or slug (post). For `PostEntity.collection`,
  use the input `collection` when supplied, else parse the collection segment from
  `filePath`. Return `.result(value: entity, dialog:)`.
- **Failure** (`.siteNotFound`, `.failed`): return `.result(value: nil, dialog:)` with the
  existing failure dialog. The optional return type is the honest one — unlike
  `DeploySiteIntent` (which returns its *param* `SiteEntity` even on failure), a create
  that failed has no created entity to return. Preserves today's graceful Siri UX.

The `#if compiler(>=6.4)` `performBackgroundTask` / `LongRunningIntent` structure and the
`ContentOperationsOverride.scoped` test seam are unchanged.

## Testing

Extend the `AnglesiteIntents` suite (Swift Testing; uses the `ContentGraphOverride` /
`ContentOperationsOverride` seams, no AppIntents runtime needed):

- **F-1:** entity round-trip still returns the expected field values after promotion
  (`entities(for:)` → assert `route`/`slug`/`collection`/`relativePath`/`siteID`).
- **F-2:** `SearchContentIntent` (via its static graph-injected helper, mirroring the
  existing `dialog(...)` test pattern) returns a uniform `[ContentMatchEntity]` matching
  the seeded graph; `ContentMatchEntityQuery.entities(for:)` resolves a mixed id list back
  to the right kinds.
- **F-3:** success returns the created entity (assert `id`/`route` for page, `id`/`slug`
  for post); `.siteNotFound`/`.failed` returns `nil` value + the expected failure dialog.
- **Chaining:** an F-2 test in the `IntentChainingTests` style — search → take a `.page`
  match → feed its `path` to a preview-style follow-up — proving the typed field is
  extractable end to end.

## Packaging

One worktree (`.claude/worktrees/163-d2-mcp-schema`), one PR closing #163, with three
reviewable commits (F-1 / F-2 / F-3). Worktree build prerequisites (per CLAUDE.md):
`xcodegen generate` first; set `ANGLESITE_PLUGIN_SRC` to the real plugin checkout
(`…/github.com/Anglesite/anglesite`) so `copy-plugin.sh` resolves.

## Out of scope / follow-ups

- Custom `AnglesiteMCPRegistration` descriptors — deferred until D.5 (#166) proves a gap.
- `SiteEntity` field promotion (directory path) — audit did not scope it; revisit if needed.
- `usedOnPages` / `isDraft` / `tags` promotion — see F-1 scope note.
- Manual Shortcuts-persistence smoke — lands on the D.5 (#166) checklist.
