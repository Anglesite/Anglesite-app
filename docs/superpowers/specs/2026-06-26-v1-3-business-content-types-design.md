# Design — V-1.3 Business content types + content-config drift guard

**Date:** 2026-06-26
**Status:** Approved design (drives the V-1.3 implementation plan)
**Issue:** [#345](https://github.com/Anglesite/Anglesite-app/issues/345) (V-1.3), part of epic [#334](https://github.com/Anglesite/Anglesite-app/issues/334) / V-1 [#335](https://github.com/Anglesite/Anglesite-app/issues/335)
**Builds on:** V-1.1 content-type registry (#372) and V-1.2 personal types (#378)

## Context

V-1.1 declared the full content-type vocabulary in `ContentTypeRegistry.swift`
(personal *and* business types) as pure data. V-1.2 wired the **personal** types
end-to-end: `content.config.ts` collections, the `Hentry.astro` layout, the
`[collection]/[...slug].astro` dynamic route, descriptor-driven scaffolding
(`ContentScaffold.renderEntry` + `NativeContentOperations.createTyped`), seed
content, and a build/render smoke test.

The business types (`businessProfile`, `announcement`, `event`, `review`) already
exist as registry descriptors but have **no** template collection, layout, route
wiring, or scaffolding. This task brings the three *collection-backed* business
types up to the same end-to-end bar as the personal types, and closes a latent gap
the pivot's "one schema, three projections" principle depends on: `content.config.ts`
is hand-authored and structurally disconnected from the registry, so the Zod
projection can silently drift from its source of truth.

## Scope

**In:**
- `announcement` (h-entry / `NewsArticle`), `event` (h-event / `Event`), `review`
  (h-review / `Review`) — end-to-end: config collection → seed content → render →
  scaffold path → smoke test.
- A registry ↔ `content.config.ts` **drift-guard test** covering **all ten
  collection-backed registry types** (the seven personal collections from V-1.2 plus
  the three new business ones). The seven personal collections are thereby locked in
  retroactively.

**Out (deferred to their own issues):**
- `businessProfile` — page-stored (`.page`) singleton h-card / `LocalBusiness`. It
  needs page-singleton scaffolding (`createTyped` rejects `.page` types today) and
  site-wide identity placement, and it overlaps V-2's site-identity / IndieAuth
  (`rel=me`) work. Tracked as a separate follow-up.
- Per-type SwiftUI editors (V-1.4).
- schema.org JSON-LD emission (V-1.8). Layouts emit **microformats2 only** in this
  pass, matching how `Hentry.astro` works today. The registry's `schemaType`
  projections (`NewsArticle`/`Event`/`Review`) are consumed later by V-1.8.
- Feeds for business collections (V-1.6 — already in flight on `feat/348-feeds`).

## Design

### 1. `content.config.ts` — three new collections

Append three `defineCollection` blocks and extend the `collections` export. Schemas
are the mechanical projection of each descriptor's fields (see the Kind→Zod contract
in §4); the `markdown` body field is **excluded** (it is the Astro entry body, not a
frontmatter field), and a non-required field gets `.optional()`.

```ts
const announcements = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/announcements" }),
  schema: z.object({
    title: z.string(),
    publishDate: z.coerce.date(),
  }),
});

const events = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/events" }),
  schema: z.object({
    name: z.string(),
    start: z.coerce.date(),
    end: z.coerce.date().optional(),
    location: z.string().optional(),
  }),
});

const reviews = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/reviews" }),
  schema: z.object({
    itemReviewed: z.string(),
    rating: z.number(),
    publishDate: z.coerce.date(),
  }),
});

export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes, announcements, events, reviews };
```

The existing `blog` collection (legacy, not in the registry) and its comment block
are left untouched.

### 2. Rendering — per-type layouts

V-1.2's `Hentry.astro` is h-entry-specific. `event` and `review` use different
microformats2 root vocabularies, so they get their own layouts (per-type layouts,
not a generic projection-driven layout — that generic approach is deferred to V-1.7,
"mf2 everywhere," where surfacing the registry projections into the template runtime
belongs).

- **`announcement`** reuses **`Hentry.astro`** unchanged (it is h-entry; `title` is
  already rendered as `p-name`).
- **`Hevent.astro`** (new) — `article.h-event` with `p-name` (name), `dt-start` and
  optional `dt-end` as `<time datetime>`, optional `p-location`, and an `e-content`
  slot for the body.
- **`Hreview.astro`** (new) — `article.h-review` with the reviewed item as `p-item`
  (the registry's `itemReviewed` → `p-item` projection), `p-rating` (rating), an
  `e-content` slot, and `dt-published`.

**`[collection]/[...slug].astro`** adds `announcements`, `events`, `reviews` to its
`getStaticPaths` collection list and selects the layout per entry by
`entry.collection`: `events` → `Hevent`, `reviews` → `Hreview`, everything else →
`Hentry`. One small switch, one file.

### 3. Scaffolding & seed content — no Swift changes

`ContentScaffold.renderEntry` and `NativeContentOperations.createTyped` are already
descriptor-driven and support collection-backed types, so the three business types
scaffold with **no Swift changes**. Add three seed entries mirroring V-1.2's
`hello-*` files so the collections build and render:

- `src/content/announcements/hello-announcement.md`
- `src/content/events/hello-event.md`
- `src/content/reviews/hello-review.md`

### 4. Drift guard — `ContentConfigDriftTests` (the new mechanism)

A **pure Swift unit test** (no Node, not gated on a buildable template). It reads
`Resources/Template/src/content.config.ts` as text and, for every
**collection-backed** descriptor in `ContentTypeRegistry.builtIns`, asserts a
matching `defineCollection` block exists with:

- the collection key present in `export const collections`;
- exactly the expected set of non-`markdown` fields (no missing, no extra);
- each field mapped to the expected Zod type;
- correct optionality (`required == false` → `.optional()`).

`blog` is legacy and not in the registry, so the test ignores collection keys with no
corresponding descriptor (it asserts registry coverage, not file exhaustiveness).

**Kind → Zod contract** (the documented mapping the test enforces):

| `ContentTypeField.Kind` | Zod |
|---|---|
| `.string`, `.text` | `z.string()` |
| `.url` | `z.string().url()` |
| `.date`, `.datetime` | `z.coerce.date()` |
| `.number` | `z.number()` |
| `.bool` | `z.boolean()` |
| `.stringArray`, `.imageArray` | `z.array(z.string())` |
| `.markdown` | *excluded* (it is the entry body, not frontmatter) |

Non-required fields append `.optional()`.

Comparison is normalized for whitespace so the hand-authored file keeps its own
formatting and comments. The guard locks in V-1.2's seven personal collections in the
same pass.

### 5. Render smoke test

Extend the `PersonalTypeRenderSmokeTests` pattern — gated on `buildable` (Node +
installed Astro), run under `TemplateBuildSerializer.shared` to avoid racing other
render-smoke suites on the shared template tree. After `astro build`, assert:

- `announcements/hello-announcement/index.html` contains `h-entry`;
- `events/hello-event/index.html` contains `h-event` and `dt-start`;
- `reviews/hello-review/index.html` contains `h-review` and `p-rating`.

## Coordination risk

`feat/348-feeds` (V-1.6, unmerged, ahead of `main`) edits the same files V-1.3 does:
`content.config.ts`, `[collection]/[...slug].astro`, `TemplateBuildSerializer`, and
the render-smoke suites. Whichever lands second rebases. V-1.3's edits are kept
**additive** (append collections, add new files, add cases to the route switch) to
minimize conflict, and the overlap is called out in the PR.

## Acceptance

- `npm run build` + `pre-deploy-check` pass with the three new collections present.
- The drift-guard test passes for all ten collection-backed types **and** demonstrably
  fails when a field is removed from `content.config.ts` (the guard is proven to bite).
- The render smoke test asserts the correct mf2 root + key properties per business
  type.
- `blog` and the seven personal collections still build and render unchanged.
