# D.1 — Intent MCP Readiness Audit

**Issue:** [#162](https://github.com/Anglesite/Anglesite-app/issues/162) (parent [#135](https://github.com/Anglesite/Anglesite-app/issues/135), Phase D — System-wide MCP exposure)
**Date:** 2026-06-17
**Spec:** [`docs/superpowers/specs/2026-06-11-siri-ai-integration-design.md`](../superpowers/specs/2026-06-11-siri-ai-integration-design.md) — Phase D

## Why this audit exists

macOS 27 exposes App Intents to external agents (Claude Code CLI, Xcode agents, other
MCP-aware apps) via the platform `mcpbridge` over XPC. Apple's bridge **auto-derives MCP
tool schemas from the App Intent / `AppEntity` schema metadata** — `@Parameter`
titles/descriptions, `@Property`-annotated entity fields, and `ReturnsValue<T>` return
types. Anything carried only in code (a plain `let`, a `displayRepresentation` subtitle
string) is invisible to that derivation.

So MCP-readiness is not about adding an MCP layer — it's about making sure the *existing*
intent/entity schema is rich enough that the auto-derived tools are usable by an agent
that has no human in the loop to read dialog strings.

## Inventory

| Intent | Module | Params | Returns | `ReturnsValue`? |
|---|---|---|---|---|
| `DeploySiteIntent` | `SiteIntents` | `site` | dialog | ✗ |
| `BackupSiteIntent` | `SiteIntents` | `site` | dialog | ✗ |
| `AuditSiteIntent` | `SiteIntents` | `site` | dialog + value | ✓ `SiteEntity` |
| `OpenSiteIntent` | `SiteIntents` | `target` | dialog | ✗ (terminal — opens UI) |
| `SearchContentIntent` | `ContentIntents` | `site`, `query` | dialog | ✗ |
| `SiteStatusIntent` | `ContentIntents` | `site` | dialog | ✗ |
| `PreviewSiteIntent` | `ContentIntents` | `site`, `page?` | dialog | ✗ (terminal — opens UI) |
| `AddPageIntent` | `ContentIntents` | `site`, `name`, `route?` | dialog | ✗ |
| `AddPostIntent` | `ContentIntents` | `site`, `title`, `collection?`, `slug?` | dialog | ✗ |
| `EditContentIntent` | `EditContentIntent` | `element`, `instruction` | dialog | ✗ |

| Entity | Disambiguating field (in `displayRepresentation`) | Carried as `@Property`? |
|---|---|---|
| `SiteEntity` | `directory.path` (subtitle) | ✗ (plain `let`) |
| `PageEntity` | `route` (subtitle) | ✗ |
| `PostEntity` | `collection/slug (+draft)` (subtitle) | ✗ |
| `ImageEntity` | `relativePath` (subtitle) | ✗ |
| `ElementEntity` | `pagePath` (subtitle) | ✗ |

## Findings against the #162 checklist

### 1. Every intent parameter has a clear `title` and type annotation — **PASS, with a gap**

Every `@Parameter` has a `title` and a concrete type. ✓

**Gap:** no parameter carries a `description:`. For entity parameters the entity's
`typeDisplayRepresentation` supplies enough context, but the **free-form `String`
parameters** (`query`, `instruction`, `name`, `route`, `title`, `collection`, `slug`)
derive a thin MCP schema — an agent sees `"Route"` with no hint that it means a
URL-path-relative slug like `/about`. These deserve a `description:` so the derived MCP
tool input schema is self-documenting.

→ **Action (this PR): add `@Parameter(description:)` to the free-form string params.**

### 2. Entity `displayRepresentation` sufficient for programmatic disambiguation — **PASS for display, GAP for chaining**

Every entity's `displayRepresentation` carries a disambiguating subtitle beyond the
display name (`route`, `relativePath`, `collection/slug`, `pagePath`, directory path). So
a human or an agent reading the rendered representation *can* tell two same-named entities
apart. ✓

**Gap:** those fields exist only as plain `let`s and as a formatted subtitle **string**.
An agent cannot extract `route` as a *typed value* to pipe into the next tool call (e.g.
"find the page → preview that page's route"). To make a field programmatically
chainable it must be promoted to `@Property`, which adds it to the entity's derived
schema.

This was a **deliberate** prior choice: `ImageEntity` documents keeping `usedOnPages` out
of the schema specifically to avoid "a source-breaking `AppEntity` schema change for
Shortcuts persistence / donated interactions." Promoting fields to `@Property` is
therefore a schema decision, **not** a "small adjustment," and is scoped as a follow-up
rather than folded into this audit pass.

→ **Action (follow-up, see below): promote `route` / `relativePath` / `slug` /
`collection` / `siteID` to `@Property`.**

### 3. Return values use `ReturnsValue<T>` where possible — **PARTIAL**

Only `AuditSiteIntent` returns a value (`SiteEntity`, enabling the audit→deploy chain from
#90). Every other intent returns dialog only, so an agent can't act on results.

- **`DeploySiteIntent`, `BackupSiteIntent`** — operate on a site and currently return
  nothing chainable. Mirroring `AuditSiteIntent` (`ReturnsValue<SiteEntity>`) lets an
  agent build deploy→backup / audit→deploy→backup chains. **Low-risk, additive** — the
  existing tests discard `perform()`'s result and assert on the injected fake's call log,
  so the return-type change does not churn them.
  → **Action (this PR).**
- **`SearchContentIntent`** — returns a spoken count only. An agent searching for content
  gets no entities back to act on. Should return the matched `PageEntity` / `PostEntity` /
  `ImageEntity` set. This is a **structural** change (the intent searches three entity
  types and currently only counts them), so it is scoped as a follow-up.
  → **Action (follow-up).**
- **`AddPageIntent`, `AddPostIntent`** — create content but return only a dialog. An agent
  can't chain "create a page → preview it." Should return the created entity (or at least
  its identifier/route). The create path returns a `ContentCreateResult`; surfacing the
  created entity needs a small amount of plumbing, scoped as a follow-up.
  → **Action (follow-up).**
- **`OpenSiteIntent`, `PreviewSiteIntent`** — terminal UI actions; dialog-only is correct.

### 4. `parameterSummary` descriptive enough for a useful MCP tool description — **PASS**

Each intent pairs a `Summary(...)` with an `IntentDescription` (e.g. "Search a site's
pages, posts, and images."). The `IntentDescription` is the natural source for the
derived MCP tool description and is adequate across the board. No change needed; the
`@Parameter(description:)` additions in finding 1 improve the *input-schema* half that the
summaries don't cover.

### 5. Entity queries handle edge cases an agent would hit — **PASS, one inconsistency**

- `PageEntityQuery` / `PostEntityQuery` / `ImageEntityQuery`: guard empty/whitespace query
  → `[]` (avoids doubling up with `suggestedEntities()` during disambiguation prefetch);
  resolve unknown ids by skipping; deterministic sort. ✓
- Ambiguous name match: queries return arrays → AppIntents disambiguates; an MCP agent
  receives all candidates. ✓
- **Inconsistency:** `SiteEntityQuery.entities(matching:)` does **not** guard the empty
  string — `name.lowercased().contains("")` is always true, so an empty query returns
  *all* sites. For `SiteEntity` (few entries) "list all" is arguably useful behavior, so
  this is recorded as an observation, **not** changed — flipping it could alter existing
  Siri/Shortcuts behavior. Noted for awareness.

## Change set applied in this PR (D.1)

1. `ReturnsValue<SiteEntity>` on `DeploySiteIntent` and `BackupSiteIntent` (all return
   paths return `.result(value: site, dialog:)`), with a deploy→backup chaining test in
   the established `IntentChainingTests` style (reconstruct the entity, assert both ops
   saw the same site id).
2. `@Parameter(description:)` on the free-form string parameters across the intents.

Both are additive, schema-safe, and match the issue's "likely small parameter/return-type
adjustments" framing.

## Recommended follow-ups (scoped out of D.1)

These are higher-value for full agent autonomy but are deliberate schema/structural
changes, so they get their own reviewed change rather than riding in an "audit" PR. They
fit naturally alongside **D.2 (#163 — custom MCP tool descriptors)**:

- **F-1 `@Property` promotion.** Promote `route` (Page), `relativePath` (Image), `slug` +
  `collection` (Post), and `siteID` (Page/Post/Image) to `@Property` so agents can extract
  typed fields for chaining. Verify Shortcuts persistence of already-donated interactions
  survives the schema bump.
- **F-2 `SearchContentIntent` structured return.** Return matched entities (not just a
  count) so an agent can search-then-act.
- **F-3 `AddPage`/`AddPostIntent` structured return.** Return the created entity/identifier
  so an agent can create-then-preview/deploy.

These map directly onto the D.2 candidate tools (`anglesite_apply_edit`,
`anglesite_list_content`): if Apple's bridge auto-derives well-shaped tools from the
improved intents above, the custom descriptors in D.2 may be unnecessary — which is what
this audit set out to determine.

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
