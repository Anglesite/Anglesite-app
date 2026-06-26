# Design — V-1.2 Personal content types (vertical slice)

**Date:** 2026-06-26
**Status:** Design (approved) — drives the #344 implementation plan
**Issue:** [#344](https://github.com/Anglesite/Anglesite-app/issues/344) (part of V-1 #335 / epic #334)
**Plan source:** [`docs/superpowers/plans/2026-06-26-personal-publishing-os-pivot-plan.md`](../plans/2026-06-26-personal-publishing-os-pivot-plan.md) §V-1, task 1.2
**Builds on:** V-1.1 content-type registry foundation ([#372](https://github.com/Anglesite/Anglesite-app/pull/372), `Sources/AnglesiteCore/ContentTypeRegistry.swift`)

## Goal

Ship the personal IndieWeb post types — **Note, Article, Photo, Album, Bookmark,
Reply, Like** — end-to-end so that each one **scaffolds**, **`astro build`s green**,
and **renders with correct microformats2 classes**. This is the #344 acceptance
criterion, taken as a self-contained vertical slice.

V-1.1 already declared descriptor *data* for note/article/photo/bookmark/reply (and
the business types). This task adds the two missing personal types (Album, Like),
makes scaffolding descriptor-driven, and adds the minimal Astro collection +
template layer so the types actually build and render.

## Settled decisions (from brainstorming)

1. **Vertical slice.** #344 takes each personal type fully through the stack:
   registry descriptor → minimal Astro collection → shared `h-entry` layout emitting
   mf2 → native scaffolding. It meets its own "scaffolds, builds, renders" acceptance
   now. Later issues *harden* the same surface: #347 (full Zod parity), #349 (mf2
   parser audit + site-wide h-card), #348 (feeds).
2. **Native, descriptor-driven scaffolding; app-only.** Frontmatter generation lives
   in Swift (`ContentScaffold` + `NativeContentOperations`), driven by the registry.
   No plugin PR. The Node `create-content.mjs` only knows page/post for now; a
   follow-up issue tracks mirroring typed scaffolding there **if/when** the MCP create
   backend needs parity.
3. **Album uses a new `imageArray` field kind.** Album is one `h-entry` with an
   `images: imageArray` field rendering multiple `u-photo`; schema.org `ImageGallery`.
   This is a small additive change to the V-1.1 `ContentTypeField.Kind` enum and gives
   the future per-type editor (#346) a real multi-photo picker.
4. **Seed content lives in the template.** One sample entry per personal collection
   ships in `Resources/Template/src/content/<collection>/` — a living example in every
   new site and the fixture the mf2 render smoke asserts against.

## Architecture

The existing seam is preserved:

- `ContentTypeRegistry` — vocabulary (pure value data; "one schema, three projections").
- `ContentScaffold` — pure, side-effect-free rendering of file contents.
- `NativeContentOperations` — the Swift create backend (resolves paths, writes, commits).
- `Resources/Template/` — the committed Astro project skeleton that consumes the types.

### 1. Registry (`Sources/AnglesiteCore/ContentTypeRegistry.swift`)

- Add `imageArray` to `ContentTypeField.Kind` (a list of site-relative media paths).
- Add two descriptors and extend `personalTypes` to
  `[note, article, photo, album, bookmark, reply, like]`:

  | type | storage | mf2 root | fields → mf2 | schema.org |
  |---|---|---|---|---|
  | `album` | `.collection("albums")` | `h-entry` | `title`(string,req)→`p-name`, `images`(imageArray,req)→`u-photo`, `body`(markdown)→`e-content`, `publishDate`(datetime,req)→`dt-published`, `tags`(stringArray)→`p-category` | `ImageGallery` |
  | `like` | `.collection("likes")` | `h-entry` | `likeOf`(url,req)→`u-like-of`, `publishDate`(datetime,req)→`dt-published` | `nil` |

### 2. Descriptor-driven scaffolding (`Sources/AnglesiteCore`)

`ContentScaffold` gains one descriptor-driven renderer; the existing
`renderPage`/`renderPost` stay for page/blog back-compat.

```swift
// ContentScaffold.swift — new, pure
static func renderEntry(descriptor: ContentTypeDescriptor,
                        title: String?, now: Date) -> String
```

- Emits YAML frontmatter keyed by the registry field names (`publishDate`, not the
  legacy `pubDate`).
- Per-kind placeholder defaults: `datetime` → `now` (ISO8601 with fractional
  seconds + internet date-time, matching `renderPost`); `date` → `now` (date only);
  `string`/`url`/`text` → `""`; `bool` → `false`; `number` → `0`;
  `stringArray`/`imageArray` → `[]`.
- A `title`/`name` field, when present and a `title` argument is supplied, is filled
  (YAML-escaped).
- The `markdown` field is rendered as the body **below** the `---` block (placeholder
  "Write your … here."), not as a frontmatter key. (Exactly one `markdown` field per
  personal type; if a type has none, the body is empty.)

```swift
// NativeContentOperations.swift — new typed entry point
func createTyped(siteID:, typeID:, title:, onProgress:) async -> ContentCreateResult
```

- Looks up the descriptor in a `ContentTypeRegistry`, derives the path via
  `ContentScaffold.postRelativePath(collection:slug:)` for `.collection` types, writes
  `renderEntry(...)`, and git-commits per existing `createPost` behavior.
- Handles `.collection` storage only. Page-stored types (e.g. `businessProfile`) are
  deferred to #345.
- **Not** wired into the UI in this task (editors are #346). It is the tested seam.

### 3. Astro template (`Resources/Template/`)

All seven personal types are `h-entry`, so a **single shared layout** renders them.

- **Collections** — `src/content.config.ts` gains loose collections (existing `blog`
  untouched): `notes, articles, photos, albums, bookmarks, replies, likes`. Schemas use
  the **registry field names**; most fields `.optional()`. Full Zod hardening is #347.
- **`src/layouts/Hentry.astro`** — wraps content in `<article class="h-entry">` and
  conditionally emits, based on which frontmatter fields are present:
  - `p-name` (title), `e-content` (body), `dt-published` (`<time datetime=…>`),
    `p-category` (tags)
  - type-specific: `u-photo` (photo single / album multiple), `u-bookmark-of`
    (bookmark), `u-in-reply-to` (reply), `u-like-of` (like)
- **Entry routes** — one thin file per collection
  (`src/pages/notes/[...slug].astro`, …): `getStaticPaths` over the collection →
  render via `Hentry.astro`. Seven small, explicit files.
- **Seed content** — one sample `.md` per collection under
  `src/content/<collection>/`.

**Not in this task:** index/listing pages, site-wide h-card, feeds (#348, #349).

## Testing & acceptance

- **`AnglesiteCoreTests` (Swift Testing):**
  - Registry: `album`/`like` descriptors + `imageArray` kind — descriptor shape, mf2
    mappings, `personalTypes` membership/order.
  - `ContentScaffold.renderEntry`: frontmatter correctness for ≥3 types — field
    coverage, per-kind defaults, `markdown` → body, ISO8601 `publishDate`.
  - `NativeContentOperations.createTyped`: writes to the correct collection path and
    commits.
- **mf2 render smoke:** runs `astro build` on the template (seeded entries) and asserts
  the expected mf2 classes appear per type. Node-dependent, so it follows the existing
  e2e pattern — skips cleanly when node/template deps are absent (mirrors
  `AppliesEditEndToEndTests`).
- **Acceptance (#344):** each personal type scaffolds; `npm run build` is green;
  rendered HTML carries the correct mf2 classes; the existing `blog` collection still
  builds.

## Out of scope (tracked elsewhere)

- Full Zod schemas / build-time type errors — #347.
- mf2 parser-validated audit + site-wide h-card — #349.
- Feeds (RSS/Atom/JSON) — #348.
- Per-type SwiftUI editors + UI wiring of `createTyped` — #346.
- App-Intent entities for new types — #351.
- Business content types (incl. page-stored `businessProfile`) — #345.
- Mirror typed scaffolding in the plugin's `create-content.mjs` for MCP-backend
  parity — **new follow-up issue** to be filed.
