# Edge Side Includes — Astro components + Component Editor integration

**Date:** 2026-07-13
**Status:** Approved design, pre-implementation
**Related:** [davidwkeith/workers#247](https://github.com/davidwkeith/workers/issues/247) (ESI issue) and [davidwkeith/workers PR #251](https://github.com/davidwkeith/workers/pull/251) (planning-only: scopes a new `@dwk/esi` processor package, no code yet), `docs/superpowers/specs/2026-07-05-component-editor-design.md` (Component Editor), [#493](https://github.com/Anglesite/Anglesite-app/issues/493) (structure ops + palette), [#494](https://github.com/Anglesite/Anglesite-app/issues/494) (Props form + typed knobs)

## 1. Summary

`davidwkeith/workers` PR #251 scoped `@dwk/esi`, a Cloudflare Worker package that
resolves `<esi:include>`/`<esi:comment>`/`<esi:remove>` markup in an outgoing
`Response` — the *processing* side of Edge Side Includes. That PR explicitly
carves out the *producing* side ("Anglesite-side markup generation... a separate
feature request against `Anglesite/Anglesite-app`") as out of scope. This spec is
that feature request: three Astro components that let a site owner author ESI
markup, plus how they plug into the in-flight Component Editor work.

The `@dwk/esi` processor doesn't exist as code yet (PR #251 is planning-only) —
that's not a blocker here, since Anglesite only ever emits static markup; whichever
order the two repos' work lands in, the markup is inert until some edge layer
processes it.

**Use case:** generic — a site owner points an include at any URL they control, no
specific `@dwk` endpoint or Anglesite feature is assumed as the fragment source.

**Non-goals:** `esi:choose`/`esi:vars`/`esi:try` (the processor's own v1 excludes
them too); choosing which endpoint(s) become fragment sources; anything in the
`workers` repo.

## 2. Placement

Three components at `Resources/Template/src/components/esi/`:
`EsiInclude.astro`, `EsiComment.astro`, `EsiRemove.astro`.

These are always-available core template components, like
[`Hcard.astro`](../../../Resources/Template/src/components/Hcard.astro) — **not**
routed through the Integration wizard/`MarkerInjector` framework used by
`integrations/components/` (BuyButton, PodcastPlayer, etc.). That framework exists
to interview a site owner about an external provider (API keys, a checkout URL, CSP
domains); ESI has no external provider to configure, just an arbitrary URL the
owner supplies per-instance, so there's nothing for an interview/wizard step to
collect.

## 3. Component shapes

All three render their `esi:*` markup via `<Fragment set:html={...} />` with
hand-escaped attribute values, rather than writing `<esi:include src={src} />`
directly in the template. Reason: it isn't verified that Astro's compiler
round-trips a colon-containing tag name (`esi:include`) through its self-closing/
serialization logic byte-for-byte, and the `@dwk/esi` tokenizer needs the *exact*
literal bytes it expects. `set:html` sidesteps that ambiguity by emitting the
string directly. **This assumption needs an empirical spike as the first
implementation task** (see §6) before anything else here is built on top of it.

### `EsiInclude.astro`

```ts
interface Props {
  src: string;
  alt?: string;
  onerror?: 'continue';
}
```

Renders `<esi:include src="…" alt="…"? onerror="continue"?></esi:include>`
verbatim (attribute values HTML-escaped, not URL-encoded — they're markup text,
not a query string). In dev mode only, also emits a client-side fetch shim; see
§4.

### `EsiComment.astro`

```ts
interface Props { text: string; }
```

Renders `<esi:comment text="…"/>` verbatim. No visible content, in dev or prod —
it's purely a template-authoring annotation that the processor drops on the floor.

### `EsiRemove.astro`

No props. Renders three pieces in sequence: the literal `<esi:remove>` open tag,
`<slot />`, then the literal `</esi:remove>` close tag. This is the one component
that needs real Astro children rather than a text macro — the fallback content it
wraps can be arbitrary markup (an image, static text, a whole `<div>`).

### Idiomatic pairing

Documented in `EsiInclude`'s own doc comment: `EsiInclude` and `EsiRemove` are
typically siblings —

```astro
<EsiInclude src="/fragments/count" onerror="continue" />
<EsiRemove><span class="count-fallback">—</span></EsiRemove>
```

**Processed** (an ESI-aware edge Worker sits in front): the fragment is spliced in
place of `EsiInclude`'s tag, and the `EsiRemove` block is stripped entirely — no
duplicate content. **Unprocessed** (a browser hits the raw HTML directly, or a
static export is opened with no edge layer at all): the unrecognized `esi:include`
tag renders empty, while `esi:remove` — also just an unrecognized element as far as
the browser is concerned — still renders *its children*, per ordinary HTML parsing
rules for unknown elements. That fallback behavior falls out of plain HTML
semantics; no shim needed for `EsiRemove` in any context.

## 4. Dev-preview behavior

Only `EsiInclude` needs special handling in local preview (Astro dev server, no
edge Worker in front) — `EsiComment` is always invisible, and `EsiRemove`'s
"unprocessed → children show" behavior described in §3 is true in dev preview for
free.

`EsiInclude.astro` conditionally emits a `<script>` block wrapped in
`{import.meta.env.DEV && (...)}` at the template level (not inside frontmatter) —
this makes Astro/Vite omit the script tag from the render tree entirely in a
production build, not merely dead-code-eliminate its contents. That script, once
per page load:

1. Selects all `esi:include` elements on the page
   (`document.querySelectorAll('esi\\:include')`, colon escaped).
2. Skips any already marked `data-esi-dev-resolved` — an idempotency guard, since
   every `EsiInclude` instance on the page emits this same script; running it N
   times is harmless, each run just skips elements a prior run already finished.
3. For each unresolved element: `fetch(src)`; on success, sets the element's
   `innerHTML` to the fragment body (mirroring how the real processor splices
   content in place of the tag) and marks it resolved. On failure: if `alt` is set,
   retry once against `alt`; otherwise (or if that also fails) leave the element
   empty. This mirrors the processor's own `onerror`/`alt`/drop rules from the
   `@dwk/esi` design doc, so dev preview approximates production behavior rather
   than showing an arbitrary placeholder.

No caching, no retries beyond the one `alt` fallback, no loading state — this is a
preview convenience, not a production feature. Keeping it minimal also keeps it
easy to audit as fully inert in a production build.

**Known preview limitation:** the dev shim's `fetch(src)` runs client-side in the
browser, so a cross-origin `src` needs that origin's own CORS headers to resolve
in preview — the production edge Worker fetch has no such restriction, since
`safeFetch` runs server-side. Worth a one-line note in `EsiInclude`'s doc comment
so a site owner isn't confused why a fragment resolves in production but shows
empty in dev preview. (A real local Worker execution path would sidestep this
entirely — see §4a for why that's out of scope here.)

## 4a. Forcing the unprocessed/fallback state

The dev shim in §4 only ever shows the *live* state (fetch succeeds, or the
`onerror`/`alt` rules kick in on failure) — there's no way to deliberately preview
what `EsiRemove`'s fallback content looks like without actually breaking the
fragment URL. A site owner needs to preview that state on purpose, not by
sabotaging their own config.

**v1 control:** the existing Debug Pane
([`DebugPaneView.swift`](../../../Sources/AnglesiteApp/DebugPaneView.swift),
backed by [`LogCenter.swift`](../../../Sources/AnglesiteCore/LogCenter.swift))
gains a new "Server" section with one control: **ESI Fragments: Live |
Unprocessed (show fallbacks)**. This reuses the existing debug window rather than
introducing a new one, and is deliberately the seed of a broader server debug
panel — see the follow-up issue in §8.

- **Live** (default): today's §4 behavior, unchanged.
- **Unprocessed:** the dev shim's step 3 (§4) is skipped entirely — no fetch is
  attempted, `EsiInclude` renders empty exactly as it would to a browser with no
  ESI-aware layer in front, and `EsiRemove`'s slotted content is what's visible.
  This exactly matches the real "unprocessed" case from §3, just forced on demand
  instead of depending on the fragment URL actually being unreachable.

The setting is stored per-site (`SiteConfigStore` / `Config/settings.plist`, app-
owned state, never in git per this repo's package model) and reaches the running
page as a query parameter the app appends when it loads the preview URL into the
WKWebView (e.g. `?esiPreview=unprocessed`); the dev shim script reads
`location.search` before deciding whether to run its fetch step at all.

**Explicitly not v1:** actually running the composed Worker (and so `@dwk/esi`
itself) locally to get real server-side resolution without the dev shim's CORS
limitation. That's a genuinely new runtime capability — nothing in the local
container runtime executes `worker/worker.ts` today, it's a production-deploy
artifact (`#353`, closed) with no local execution path — and is filed separately
rather than folded into this spec; see §8.

## 5. Component Editor integration

Once [#493](https://github.com/Anglesite/Anglesite-app/issues/493) (structure ops
+ palette: `insert-node`/`move-node`/`remove-node`/`set-attr`, palette listing
project components, sealed component instances with slot-fill drop areas) lands,
all three components need **no ESI-specific Component Editor code** to appear in
the palette or accept prop edits — they're ordinary project components under
`src/components/esi/`, and `EsiRemove`'s `<slot />` makes it a normal "sealed
instance with a slot-fill drop area" per #493's existing plan.

Two concrete, ESI-motivated gaps are worth folding into #493/#494 directly (issue
bodies updated as part of this work — see §7), rather than filed as a new issue:

- **#493 refinement (optional):** if a component has a leading frontmatter doc
  comment, the palette could show it as a one-line description/tooltip — e.g.
  `EsiInclude`'s comment would read "Edge-fetched fragment — spliced in at the
  edge, or fetched client-side in dev preview." Not required for ESI to work, just
  improves discoverability of components named after markup most site owners
  won't recognize on sight. A nicety for #493's implementer to accept or drop.
- **#494 refinement (real gap):** `EsiInclude`'s `onerror?: 'continue'` is a
  TypeScript string-literal type, not `string`/`number`/`boolean`. Today's
  `KnobDefaults.value(for:)`
  ([`ComponentOutline.swift:109-121`](../../../Sources/AnglesiteCore/ComponentOutline.swift))
  only special-cases those three primitive type names — a literal-union type falls
  through to the empty-string default, so `onerror` would render as a blank
  free-text field rather than a constrained choice. #494's "structured Props form"
  work should parse simple string-literal-union prop types (`'a' | 'b' | 'c'`) and
  render them as a picker/segmented control, the same way `boolean` already gets a
  toggle instead of free text. `EsiInclude` becomes the concrete test case for that
  parsing logic when #494 is implemented. `src`/`alt` stay plain `string` — no
  dedicated URL-typed control proposed for v1.

**Net effect:** the three Astro components ship independently of #493/#494's
timeline (usable today via hand-edited markup) and automatically gain palette +
prop-editing UX as those slices land — this spec adds no new Swift/Component
Editor code of its own, only the one type-parsing refinement folded into #494.

## 6. Error handling & edge cases

- **Empty/missing `src`** — `EsiInclude.src` is a required prop; an empty string
  is a site-owner authoring mistake surfaced by Astro/TypeScript's own prop
  validation at build time, not a runtime case this component handles.
- **`EsiRemove` with no children** — valid; renders `<esi:remove></esi:remove>`
  with nothing between, trivially matching "strip the block" since there's nothing
  to strip.
- **Multiple `EsiInclude`s with the same `src`** — no dedup; each fetches
  independently in dev preview (and resolves independently at the edge in prod).
  Not worth optimizing for v1.

## 7. Testing plan

- **Astro build fixture test:** a page using all three components; assert the
  built static HTML contains the literal `<esi:include>`/`<esi:comment>`/
  `<esi:remove>` byte sequences unchanged. This is the empirical check for the §3
  assumption about Astro's compiler behavior — **the first implementation task**,
  before anything else in this spec is built.
- **Dev shim test:** stub `fetch`, render `EsiInclude` in dev mode, assert resolved
  content lands in the DOM; a second case asserts the shim's `<script>` tag is
  entirely absent from a production build's output (not just inert).
- **Unprocessed-toggle test:** with `?esiPreview=unprocessed` set, assert the dev
  shim never calls `fetch` at all and `EsiRemove`'s slotted content is what
  renders.
- **Swift-side:** a test for the new Debug Pane "Server" section's Live/Unprocessed
  control persisting to `SiteConfigStore` and producing the right query parameter
  when the app builds the preview URL. No other new Swift-side tests — Component
  Editor integration rides on #493/#494's own test coverage.

## 8. Explicitly out of scope / follow-ups

- `esi:choose`/`esi:vars`/`esi:try` — deferred, matches the processor's own v1
  scope.
- Any Component Editor Swift code — deferred to #493/#494; this spec only
  proposes refinements to those issues, doesn't implement against them.
- Choosing `@dwk` endpoints as fragment sources, and the `@dwk/esi` processor
  itself — both remain `workers`-repo concerns.
- **General server debug panel** — running the composed Worker locally,
  configuring production behavior beyond ESI's one toggle, and viewing worker +
  analytics logs. Filed as
  [#699](https://github.com/Anglesite/Anglesite-app/issues/699) for its own
  design pass; this spec's §4a is deliberately the minimal slice of that
  eventual panel, not a preview of its full shape.
