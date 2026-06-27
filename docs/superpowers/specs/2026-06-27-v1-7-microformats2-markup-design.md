# V-1.7: microformats2 markup in type templates — design

**Issue:** #349 (part of V-1, epic #335 / #334)
**Date:** 2026-06-27
**Status:** approved, pre-implementation

## Goal

Complete microformats2 (mf2) property coverage in the **entry-layer** templates so
every routed content type emits valid `h-entry` / `h-review` / `h-event`, and add a
parser-based test that proves the rendered output is valid mf2.

## Scope boundary with #388

The issue's acceptance has two halves:

1. **"output validates against an mf2 parser"** — owned by this issue (#349).
2. **"site-wide h-card present"** — delegated to **#388** (the `businessProfile`
   page-singleton). #388 *is* the site identity h-card / `LocalBusiness`, and it is in
   active development on `feat/388-site-identity`.

Therefore **author `p-author` h-card and the site-wide h-card are out of scope here.**
Both need #388's identity data model as their source; building them in #349 would
collide with active work and duplicate the data model. The harness ships with those
assertions present but skipped, so #388 can switch them on when it lands its h-card.

This keeps #349 small, dependency-clean, and collision-free, and hands #388 a
ready-made mf2 validator to land its h-card against.

## Current state (what already exists)

mf2 is roughly 70% present in the three entry layouts:

- `Hentry.astro` (8 collections: notes, articles, photos, albums, bookmarks, replies,
  likes, announcements) emits `h-entry`, `p-name`, `u-photo`, `u-bookmark-of`,
  `u-in-reply-to`, `u-like-of`, `e-content`, `dt-published`, `p-category`. It carries an
  explicit `TODO(#349)` at line 41: article `summary` is not emitted as `p-summary`
  (only photo `caption` is).
- `Hreview.astro` emits `h-review`, `p-name`, `p-item`, `p-rating`, `e-content`,
  `dt-published`. Already guards the implied-name pitfall (explicit `p-name` so the
  parser doesn't smash item/rating/body into the name).
- `Hevent.astro` emits `h-event`, `p-name`, `dt-start`, `dt-end`, `p-location`,
  `e-content`.
- `BlogPost.astro` (the flagship article type, routed separately via
  `src/pages/blog/[...slug].astro`) emits **no mf2 at all** — plain `<article>`, `<h1>`,
  `<time>`. This is the largest gap.

Constraints discovered:

- The template has **no author / site-identity data source**. The only config is
  `.site-config` (`SITE_URL=…`) read via `scripts/config.ts` `readConfig()`. (This is
  precisely why the site-wide h-card belongs to #388, which introduces the identity
  model.)
- Tests use **`node:test` + `node:assert/strict` run via `tsx`** (see
  `src/lib/feeds.test.ts`, `scripts/config.test.ts`). No vitest. No mf2 parser dep yet.
- `Astro.url` inside each layout is already the entry's permalink during render, so
  `u-url` needs no prop threading.

## Design

### 1. Template changes (additive markup only — no data-model changes)

**`BlogPost.astro`** — add full h-entry:

- `<article class="h-entry">`
- `<h1 class="p-name">{title}</h1>`
- `description` → `<p class="p-summary">{description}</p>` (when present)
- wrap `<slot/>` in `<div class="e-content">`
- `pubDate` → `dt-published` (existing `<time>` gains the class)
- `u-url` permalink (see pattern below)
- The `← All posts` nav stays **outside** `<article class="h-entry">` so it cannot
  pollute implied properties; the `<!-- anglesite:comments -->` anchor stays **outside**
  `e-content` (comments are not part of the post content) — it may remain inside the
  article, after the content div.

**`Hentry.astro`** — resolve `TODO(#349)`:

- Emit `p-summary` for article `summary`. An entry carries either a photo `caption` or an
  article `summary` (not both), so emit whichever is present into a single `p-summary`.

**All three entry layouts (`Hentry`, `Hreview`, `Hevent`)** — add `u-url`:

- Use `Astro.url.pathname` (already the entry's URL). Pattern: wrap the existing
  published/start `<time>` in `<a class="u-url" href={Astro.url.pathname}>…</a>`
  (standard indieweb date-as-permalink). Every routed entry has a date field, so the
  time element is always available as the permalink anchor.

### 2. Validation harness

- Add **`microformats-parser`** as a devDependency (maintained, pure-TS mf2 parser).
- New test file `src/layouts/microformats.test.ts`, `node:test` + `tsx` style.
- Render each real layout to an HTML string with **`experimental_AstroContainer`**
  (`astro/container`), passing representative sample props + slot body. Parse the
  rendered HTML with `microformats-parser`. Assert:
  - exactly one root item of the expected type (`h-entry` / `h-review` / `h-event`)
  - required properties present and correctly valued:
    - h-entry: `name`, `published`, `content` (+ `summary` for the article fixture,
      `category` for a tagged fixture)
    - h-review: `name`, `item`, `rating`
    - h-event: `name`, `start`
  - `url` property present (the new `u-url`)
  - a sanity assertion that `name` equals the explicit title, **not** the implied-name
    concatenation (guards the pitfall `Hreview.astro` already documents)
- Author / site-wide-h-card assertions are written as **`it.skip(...)` placeholders**
  with a `// #388` note, so #388 can enable them when it ships the h-card.

If the Container API needs a request URL for `Astro.url` to resolve `u-url`
deterministically, set it via the container render options; this is an implementation
detail, not a design risk.

### 3. Testing & acceptance

- `npx tsx --test src/layouts/microformats.test.ts` passes.
- `astro check` remains clean (changes are type-neutral markup).
- Acceptance "output validates against an mf2 parser" — met by the harness.
- Acceptance "site-wide h-card present" — explicitly delegated to #388 (recorded on both
  issues); the skipped assertions document the seam.

## Out of scope (YAGNI)

- Author `p-author` h-card and site-wide h-card → **#388**.
- No `dist/` post-build mf2 guard in `pre-deploy-check.ts` (the Container-API unit test
  covers validation without a full build; a build-time guard can be a later follow-up if
  wanted).
- No `p-best` / `p-worst` on reviews (mf2's default 1–5 scale is correct for the bare
  `rating` number).
- No nested `h-card` / `h-adr` for event location (text `p-location` is valid mf2).

## Files touched

- `Resources/Template/src/layouts/BlogPost.astro` (mf2 added)
- `Resources/Template/src/layouts/Hentry.astro` (`p-summary` for article summary, `u-url`)
- `Resources/Template/src/layouts/Hreview.astro` (`u-url`)
- `Resources/Template/src/layouts/Hevent.astro` (`u-url`)
- `Resources/Template/src/layouts/microformats.test.ts` (new)
- `Resources/Template/package.json` (+ `microformats-parser` devDependency)
