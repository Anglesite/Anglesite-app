# Phase A Closeout — Design

**Date:** 2026-06-16
**Issues:** #143 (A.9 — e2e integration test), #139 (A.5 — content intents, verify + close)
**Spec parent:** [`2026-06-11-siri-ai-integration-design.md`](2026-06-11-siri-ai-integration-design.md) — Phase A

## Context

Phase A's foundation shipped across PRs #136–#142, #170, #193 (June 12–14). An exploration
of the merged code found that **the A.5 content intents are already implemented**:

- `Sources/AnglesiteIntents/ContentIntents.swift` — `SearchContentIntent`, `SiteStatusIntent`,
  `PreviewSiteIntent`, `AddPageIntent`, `AddPostIntent`, plus the pure `ContentDialogs` helpers.
- `Sources/AnglesiteIntents/EditContentIntent.swift` — `EditContentIntent` (landed via B.5 / #149).
- All registered with Siri phrases in `AnglesiteShortcuts.swift`; unit-tested in
  `ContentIntentsTests.swift` / `EditContentIntentTests.swift`.

So issue #139 is **stale** — the code landed but the issue was never closed. Two genuine gaps remain
to close Phase A:

1. **#143 (A.9)** — no single test stitches the full pipeline together. The segments are each
   covered in isolation (`ContentListingTests`, `LocalSiteRuntimeGraphTests`, `ContentEntitiesTests`,
   `ContentSpotlightIndexerTests`) but the end-to-end chain through to the Spotlight diff is untested.
2. **`PreviewSiteIntent` page navigation** — the intent accepts a `page: PageEntity?` parameter it
   does not use; a code comment (`ContentIntents.swift:88-90`) defers delivering the route to the
   open window's `WKWebView`. This is a real, spec'd-but-deferred feature.

Closing both finishes Phase A, which per the parent spec's dependency graph unblocks **all of
Phase D** (system-wide MCP, #162–#166).

## Goals

- Add the A.9 end-to-end integration test (#143).
- Implement `PreviewSiteIntent` page navigation, including the cold-open case.
- Verify #139's intents compile and pass; close #139 and #143.

## Non-goals (YAGNI)

- No changes to `EditContentIntent` or the plugin's `apply-instruction` op (Phase C / plugin work).
- No client-side in-page routing — a full `WKWebView` reload at the target route is fine for v0.
- No multi-window route arbitration beyond the consume-once pairing described below.
- No new plugin paired PR — `list_content` / `create_page` / `create_post` already shipped (#140).

---

## Part A — #143 (A.9) end-to-end integration test

### Location & target

`Tests/AnglesiteIntentsTests/` (new file, e.g. `ContentPipelineE2ETests.swift`), extending the
existing `@Suite("AppIntents", .serialized)` suite. The chain spans both modules — the graph lives
in `AnglesiteCore`, the entity queries and indexer in `AnglesiteIntents` — and only
`AnglesiteIntentsTests` can `@testable import` both. `SiteContentGraph` and `ContentSpotlightBackend`
are `public`; `ContentGraphOverride` is internal and reached via `@testable import AnglesiteIntents`.

### Test substrate: pure in-memory, always-on (Decision 1)

The test feeds a realistic `list_content`-shaped JSON payload through the **real**
`ContentListing.parse(jsonText:siteID:)` — no Node, no Python, no gating. It runs on every CI push.

Rationale for deviating from the parent spec's "XCTSkip when node absent": the MCP-round-trip →
graph-population segment is already covered by `LocalSiteRuntimeGraphTests` (fake Python server,
gated on `pythonAvailable`). A.9's *novel* coverage is steps 3–5 (entity-query resolution +
Spotlight diff-on-mutation) — exactly the regression guard we want running everywhere, not skipped
on runners without Python. Exercising the real parser on the real payload shape keeps the parse
contract honest without the subprocess.

### The chain asserted

Using only APIs confirmed present in the merged code:

1. **Parse** — `ContentListing.parse(jsonText:siteID:)` on a canned payload with ≥2 pages, ≥2 posts
   (one `draft: true`), ≥1 image → assert counts and a sampling of fields (route, slug, draft).
2. **Populate** — `graph.load(siteID:pages:posts:images:)` → `pages(for:)` / `posts(for:)` /
   `images(for:)` return the loaded content.
3. **Resolve entities** — inside `ContentGraphOverride.$scoped.withValue(graph)`, call
   `PageEntityQuery().entities(for:)`, `PostEntityQuery().entities(for:)`,
   `ImageEntityQuery().entities(for:)` → assert they resolve from the graph (ids + a field each).
4. **Index** — `ContentSpotlightIndexer(graph:backend:)` with a `RecordingBackend` actor (the
   established test-backend pattern from `ContentSpotlightIndexerTests`). `reindex(siteID:)` →
   assert `Outcome(indexed:removed:)` and the backend's recorded `indexPages/Posts/Images` calls
   match the loaded set.
5. **Mutation diff** — `graph.upsertPage(_:)` (changed) and `graph.removePost(id:)` (removed),
   then `reindex(siteID:)` again → assert the second pass re-indexes the changed page and calls
   `deletePosts(identifiers:)` for the removed post, leaving untouched entities consistent.

### Boundary

This is a deterministic, in-process test of the data pipeline. It does **not** exercise the live
`LocalSiteRuntime` MCP spawn (already covered) or the AppIntents runtime's `perform()` (covered by
`ContentIntentsTests`). It is the missing seam: parser → graph → entity query → Spotlight diff.

---

## Part B — `PreviewSiteIntent` page navigation

### Seam: extend `WindowRouter` (smallest change)

`WindowRouter` (`Sources/AnglesiteIntents/WindowRouter.swift`, `@MainActor @Observable` singleton)
gains an optional route paired with the open request:

```swift
public var requested: String?
public var requestedRoute: String?           // route for `requested`, consumed once

public func requestOpen(siteID: String, route: String? = nil) {
    requested = siteID
    requestedRoute = route
}
```

The default-`nil` parameter preserves the existing no-route call sites. `PreviewSiteIntent.perform()`
becomes `WindowRouter.shared.requestOpen(siteID: site.id, route: page?.route)`. The route and siteID
are set and consumed together, so the route is unambiguously "the route for the site we just asked
to open."

### Pure, testable route→URL composition (Decision: CI-coverable core)

Per CLAUDE.md, App-target types (`PreviewModel`, `PreviewView`, `SiteWindow`) are not CI-testable
(hosted app tests are blocked on macOS-15 runners). So the only logic worth testing — composing the
target URL from the dev-server base URL and a page route — is extracted into a pure helper in
`AnglesiteCore`, unit-tested in `AnglesiteCoreTests`:

```swift
public enum PreviewNavigation {
    /// Compose the absolute preview URL for `route` against the dev-server `base`.
    /// `route` is treated as an absolute site path; the base's scheme/host/port are preserved.
    public static func targetURL(base: URL, route: String) -> URL
}
```

Behavior to specify and test:
- `route == "/"` or empty → returns `base` (the site root).
- `"/about"` → `<base scheme/host/port>/about`.
- `"about"` (no leading slash) → same as `"/about"` (normalized).
- Nested `"/blog/post-1"` → preserved.
- A `base` carrying a trailing slash does not produce a double slash.
- Implemented via `URLComponents(url: base)` with a normalized `path`, not naive string concat.

### App-target glue (thin, not CI-tested)

- **`PreviewModel`** gains `private(set) var navigationTarget: URL?` (`@Observable`) and a
  `private var pendingRoute: String?`. New `func navigate(toRoute:)`:
  - If the runtime is `.ready(_, base)`, set `navigationTarget = PreviewNavigation.targetURL(base:route:)`.
  - Otherwise stash `pendingRoute`; when the runtime transitions to `.ready`, apply and clear it
    (this is the **cold-open** case — Decision 2 — and is the common Siri path, where no window is
    open yet).
- **`PreviewView`** loads `navigationTarget ?? readyURL` so a route override navigates the same
  `WKWebView` via the existing `webView.load(URLRequest:)` path. No new web-view API.
- **`SiteWindow`**, when it handles the open for the requested site, consumes
  `WindowRouter.shared.requestedRoute` (for the matching siteID), calls `preview.navigate(toRoute:)`,
  and clears `requestedRoute`. The consume-once pairing avoids a route leaking into the wrong window.

### Dialog

`ContentDialogs.preview` gains an optional page so the spoken result reflects navigation, e.g.
"Opening the About page of MySite." when a `page` is supplied, falling back to "Opening MySite."
when not. Pure and unit-tested alongside the existing `ContentDialogs` tests.

---

## Part C — Verify #139 and close out

1. Confirm the existing intents (`ContentIntents.swift`, `EditContentIntent.swift`) compile and
   their tests pass on this branch — they predate the issue closure.
2. Build **both** schemes with `xcodebuild` (not just `swift test` — App-target wiring like the
   `PreviewModel`/`SiteWindow` glue only links in the real app): `Anglesite` (DevID) and
   `AnglesiteMAS`. In this worktree, run `xcodegen generate` first and set `ANGLESITE_PLUGIN_SRC`
   to the sibling plugin checkout (the default `../anglesite` resolves wrong from a worktree).
3. Run `swift test` for the `AnglesiteCore` + `AnglesiteIntents` suites (new A.9, `PreviewNavigation`,
   `WindowRouter`, `ContentDialogs` tests included).
4. Close **#139** (code shipped earlier; note that in the close comment) and **#143** (delivered here).

## Testing summary

| Test | Target | CI |
|---|---|---|
| A.9 e2e pipeline (parse → graph → entity query → Spotlight diff) | `AnglesiteIntentsTests` | always-on |
| `PreviewNavigation.targetURL` route→URL cases | `AnglesiteCoreTests` | always-on |
| `WindowRouter.requestOpen(siteID:route:)` sets/omits route | `AnglesiteIntentsTests` | always-on |
| `ContentDialogs.preview(page:)` phrasing | `AnglesiteIntentsTests` | always-on |
| `PreviewModel` / `PreviewView` / `SiteWindow` glue | App target | build-verified only (per CLAUDE.md) |

## Risks & mitigations

- **App-glue untested on CI.** Mitigated by extracting the only non-trivial logic
  (`PreviewNavigation`) into a CI-tested Core helper and keeping the glue mechanical; both schemes
  are build-verified.
- **Cold-open lifecycle race** (route applied before `.ready`). Mitigated by the `pendingRoute`
  stash-then-apply on the `.ready` transition rather than a fire-and-forget navigate.
- **Spec drift confirmed, not assumed.** The API surface was mapped against merged code before
  designing; no reliance on the parent spec's idealized signatures.
