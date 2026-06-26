# V-1.6 Feeds (RSS / Atom / JSON) — Design

> Issue: [#348](https://github.com/Anglesite/Anglesite-app/issues/348) — part of the V-1 typed-content epic [#335](https://github.com/Anglesite/Anglesite-app/issues/335).

**Goal:** Every content collection in `Resources/Template/` publishes a syndication feed in three formats — RSS 2.0, Atom 1.0, and JSON Feed 1.1 — co-located inside the collection, plus a site-wide combined feed. Feeds are valid at build time and survive `pre-deploy-check`.

## Dependency — gated on #344

The feed set covers **all** content collections, but only `blog` exists on `main` today. The personal-type collections (`notes`, `articles`, `photos`, `albums`, `bookmarks`, `replies`, `likes`) are being created by V-1.2 ([#344](https://github.com/Anglesite/Anglesite-app/issues/344)). **This implementation must not start until #344 has merged to `main`** — the per-collection feed routes and the combined aggregator reference those collections by name and will not compile without them.

The design and the implementation plan are written now (against #344's committed schema) so execution can begin the moment #344 lands. Field names and collection names below are taken verbatim from #344's plan to stay in lockstep.

## Global Constraints

- **App-only, template-only.** No plugin PR, no `Resources/plugin` change. All work lands under `Resources/Template/` plus one node-gated Swift smoke test.
- **ES Modules**, vanilla — Astro 5 + `@astrojs/rss` only. No other new dependencies.
- **Registry-named fields.** Feed code reads the field names each collection actually uses — `blog` uses `pubDate`; the typed collections use `publishDate`. The per-collection feed config table is the single place this difference is declared.
- **Swift Testing** (`@Test`/`#expect`) for the smoke test, gated to skip (not fail) when template deps are absent — mirroring `PersonalTypeRenderSmokeTests` from #344.
- **Conventional commits.**

## Collections in scope

| Collection | Title field | Date field | Notes |
|---|---|---|---|
| `blog` | `title` | `pubDate` | existing; legacy date field name |
| `notes` | — (none) | `publishDate` | title-less → derive from body |
| `articles` | `title` | `publishDate` | has `summary` |
| `photos` | — (`caption`) | `publishDate` | caption as summary |
| `albums` | `title` | `publishDate` | |
| `bookmarks` | `title?` | `publishDate` | title optional → fall back to `bookmarkOf` host |
| `replies` | — (none) | `publishDate` | title-less → derive from body |
| `likes` | — (none) | `publishDate` | title-less → derive from `likeOf` |

## Architecture

Feed **logic** lives in exactly one module; each collection owns thin **route** files that delegate to it. This keeps every collection self-contained (its feed endpoints sit beside its pages) without duplicating serialization.

### 1. `src/lib/feeds.ts` — the shared module

- **`FEED_COLLECTIONS`** — an ordered config table, one entry per collection:
  ```ts
  interface FeedCollection {
    name: string;            // collection name, e.g. "blog"
    title: string;          // human feed title, e.g. "Blog"
    dateField: string;      // "pubDate" | "publishDate"
    toItem(entry): FeedItem; // maps a collection entry to a normalized item
  }
  ```
  `toItem` produces a normalized `FeedItem { title, link, date, summary, content }`. Title-less types derive a title from the first ~80 chars of body text (`note`, `reply`), from the link host (`like`, untitled `bookmark`), or from `caption` (`photo`). `link` is the entry's canonical permalink (`/<collection>/<id>/`), resolved to absolute against `site`.
- **`getFeedItems(collectionName, limit?)`** — loads the collection via `getCollection`, drops drafts where applicable, sorts by the configured date field descending, maps through `toItem`, applies an optional `limit`.
- **`getCombinedItems(limit = 50)`** — concatenates all collections' items, sorts by date descending, caps at `limit`.
- **Three serializers:**
  - `buildRss(context, collectionName?)` — wraps `@astrojs/rss`'s `rss()`; `collectionName` omitted → combined.
  - `buildAtom(context, collectionName?)` — returns a `Response` with hand-written Atom 1.0 XML (`<feed>`/`<entry>`, `id`, `updated`, `link rel="self"`).
  - `buildJsonFeed(context, collectionName?)` — returns a `Response` with a JSON Feed 1.1 object (`version`, `title`, `home_page_url`, `feed_url`, `items[]`).
  All three pull the absolute base from `context.site` (Astro injects it from `astro.config`'s `site`). XML/JSON values are escaped; dates are emitted as RFC-822 (RSS) / RFC-3339 (Atom, JSON).

### 2. Per-collection route files (co-located)

Inside each collection's page directory, three thin endpoints:

```
src/pages/<collection>/rss.xml.ts     export const GET = (ctx) => buildRss(ctx, "<collection>")
src/pages/<collection>/atom.xml.ts    export const GET = (ctx) => buildAtom(ctx, "<collection>")
src/pages/<collection>/feed.json.ts   export const GET = (ctx) => buildJsonFeed(ctx, "<collection>")
```

Routing: `/<collection>/rss.xml` resolves to the endpoint, **not** the collection's `[...slug].astro` — Astro ranks named/static routes above `[...spread]` params, so the two coexist. The build smoke verifies this.

### 3. Site-wide combined feed (root)

```
src/pages/rss.xml.ts    export const GET = (ctx) => buildRss(ctx)
src/pages/atom.xml.ts   export const GET = (ctx) => buildAtom(ctx)
src/pages/feed.json.ts  export const GET = (ctx) => buildJsonFeed(ctx)
```

### 4. `astro.config.mjs` — site URL

Reads `SITE_URL` from `.site-config` (the existing `scripts/config.ts` `readConfig` pattern; same file CSP reads `SCRIPT_ALLOW` from), falling back to `https://example.com` when unset:

```js
import { readConfig } from "./scripts/config.ts";
const site = readConfig("SITE_URL") ?? "https://example.com";
export default defineConfig({ site });
```

The deploy step is responsible for writing the real `SITE_URL` into `.site-config` before build; absent that, feeds carry the placeholder host (acceptable for a not-yet-deployed scaffold).

### 5. Autodiscovery

`BaseLayout.astro` `<head>` gains `<link rel="alternate">` tags for the three **combined** feeds (`application/rss+xml`, `application/atom+xml`, `application/feed+json`). Each collection's `index.astro` adds an alternate link to its own RSS feed so readers on a collection page discover that collection's feed.

## Data flow

```
.site-config (SITE_URL) ──► astro.config site ──► context.site
                                                      │
getCollection(<name>) ──► sort by dateField ──► toItem() ──► FeedItem[]
                                                      │
              buildRss / buildAtom / buildJsonFeed ──► Response (xml/json)
```

## Error handling

- A missing/empty collection yields a valid empty feed (channel metadata, zero items) — never a build error.
- `toItem` always produces a non-empty `title` and `content`/`summary` (the derivation fallbacks guarantee this), so title-less types never emit an empty `<title>`.
- `astro.config` never throws on a missing `.site-config`; it falls back to the placeholder.

## Testing

1. **Node-gated build smoke** — `Tests/AnglesiteCoreTests/FeedsRenderSmokeTests.swift`, `.enabled(if:)` on Node + installed Astro (same gate as `PersonalTypeRenderSmokeTests`). Builds the template and asserts, in `dist/`:
   - each collection emits `rss.xml`, `atom.xml`, `feed.json`;
   - the root combined `rss.xml` / `atom.xml` / `feed.json` exist;
   - a title-less `notes` feed item still carries a non-empty `<title>` and content;
   - feeds contain absolute URLs built from `site`.
2. **`pre-deploy-check`** stays green with the new endpoint routes (run `npm run check`).
3. Optional, fast: a Node unit test for `feeds.ts` `toItem` derivations (title-less fallbacks, date-field selection) if the build smoke proves too coarse — decided during planning.

## Out of scope

- Per-format autodiscovery for every collection beyond RSS (combined gets all three; collection indexes link RSS only).
- Feed pagination / `rel="next"`; the combined feed simply caps at 50.
- WebSub/hub advertisement (that's V-3.3, [#361](https://github.com/Anglesite/Anglesite-app/issues/361)).
- Full Zod hardening of schemas ([#347](https://github.com/Anglesite/Anglesite-app/issues/347)) and mf2 markup ([#349](https://github.com/Anglesite/Anglesite-app/issues/349)).

## Self-review

- Formats: RSS + Atom + JSON — all three, per issue title. ✓
- Site URL: `SITE_URL` in `.site-config`, placeholder fallback. ✓
- Scope: all collections; **gated on #344**, design written now. ✓
- Self-contained collections: feed routes co-located per collection; shared logic in `src/lib/feeds.ts`. ✓
- Combined feed at root. ✓
- Date-field divergence (`pubDate` vs `publishDate`) handled by the per-collection config table. ✓
- Title-less types handled by `toItem` derivations. ✓
- Testing: node-gated smoke + pre-deploy-check. ✓
