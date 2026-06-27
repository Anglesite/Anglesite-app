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

**Runner decision (corrected during planning):** the Astro **Container API cannot run
on the template's `node:test`/`tsx` runner** — `tsx` cannot compile `.astro` imports
(`ERR_UNKNOWN_FILE_EXTENSION ".astro"`, confirmed empirically), so it would require
adding **Vitest** + `getViteConfig`. Instead — and because **the scaffold already ships
exactly one sample entry in every collection** — the harness validates the **true built
output**, which both avoids a second test runner and more literally satisfies "output
validates against an mf2 parser."

- Add **`microformats-parser`** as a devDependency (maintained, pure-TS mf2 parser;
  `mf2(html, { baseUrl }) → { items, rels, "rel-urls" }`).
- **Validator module** `scripts/microformats.ts` — pure, build-independent logic:
  - `findRoots(html, baseUrl)` → root mf2 items via `microformats-parser`.
  - `validateEntryHtml(html, baseUrl)` → returns `string[]` of problems for one page:
    exactly one root item; its type is one of `h-entry`/`h-review`/`h-event`; required
    properties present (`name`, `url`, and `published` for entry/review or `start` for
    event; review also `rating`); `name` is the explicit title, **not** the implied-name
    concatenation (guards the pitfall `Hreview.astro` documents).
  - `validateDist(distDir)` → walks `dist/**/*.html` under the entry collection dirs
    (`blog`, `notes`, `articles`, `photos`, `albums`, `bookmarks`, `replies`, `likes`,
    `announcements`, `events`, `reviews`), runs `validateEntryHtml` on each, and asserts
    **coverage**: each of the three vocab types (`h-entry`, `h-review`, `h-event`)
    appears at least once. Returns aggregated problems.
- **CLI** `scripts/check-microformats.ts` — runs `validateDist("dist")`, prints
  problems, exits non-zero on failure. Wired into the `build` script *after*
  `astro build` so every build guards mf2 validity (mirrors the existing
  `pre-deploy-check.ts` guard philosophy).
- **Unit test** `scripts/microformats.test.ts` — `node:test` + `tsx`, no build, no
  `.astro`. Feeds `validateEntryHtml` representative **HTML fixture strings**:
  - a good `h-entry` (article) → no problems; assert parsed `name`/`summary`/`published`/
    `url`/`content`/`category`.
  - a good `h-review` → no problems; assert `name`/`item`/`rating`/`url` and the explicit
    name.
  - a good `h-event` → no problems; assert `name`/`start`/`location`/`url`.
  - a bad fixture (missing `u-url`, or an `h-review` with no explicit `p-name` so the
    implied name smashes item/rating/body) → non-empty problems list.
- Author / site-wide-h-card assertions are written as **`test(... , { skip: true })`
  placeholders** with a `// #388` note, so #388 can enable them when it ships the h-card.

This separates concerns cleanly: `microformats.test.ts` proves the validator logic with
fast fixtures (the part that needs a review gate), and the post-build CLI proves the
**real** site output passes (the part that needs a build).

### 3. Testing & acceptance

- `npx tsx --test scripts/microformats.test.ts` passes (validator-logic unit tests).
- `npm run build` succeeds **and** the post-build `check-microformats` CLI passes against
  the real `dist/` produced from the scaffold's seeded content — the literal "output
  validates against an mf2 parser" acceptance.
- `astro check` remains clean (changes are type-neutral markup).
- Acceptance "site-wide h-card present" — explicitly delegated to #388 (recorded on both
  issues); the skipped tests document the seam.

## Out of scope (YAGNI)

- Author `p-author` h-card and site-wide h-card → **#388**.
- No Vitest / Container API (would add a second test runner; the post-build dist
  validator covers the acceptance on the existing `node:test` runner).
- No `p-best` / `p-worst` on reviews (mf2's default 1–5 scale is correct for the bare
  `rating` number).
- No nested `h-card` / `h-adr` for event location (text `p-location` is valid mf2).

## Files touched

- `Resources/Template/src/layouts/BlogPost.astro` (mf2 added)
- `Resources/Template/src/layouts/Hentry.astro` (`p-summary` for article summary, `u-url`)
- `Resources/Template/src/layouts/Hreview.astro` (`u-url`)
- `Resources/Template/src/layouts/Hevent.astro` (`u-url`)
- `Resources/Template/scripts/microformats.ts` (new — validator module)
- `Resources/Template/scripts/check-microformats.ts` (new — post-build CLI)
- `Resources/Template/scripts/microformats.test.ts` (new — validator unit tests)
- `Resources/Template/package.json` (+ `microformats-parser` devDependency; `build`
  script gains the post-build validator)
