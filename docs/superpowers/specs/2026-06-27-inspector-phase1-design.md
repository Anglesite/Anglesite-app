# Inspector — Phase 1: shell + page-level metadata — design

**Issue:** extends [#346](https://github.com/Anglesite/Anglesite-app/issues/346) (V-1.4). Reworks #346's presentation; first phase of a larger Inspector epic.
**Date:** 2026-06-27
**Status:** Approved (brainstorm)

## Vision (the epic)

Every page has metadata that isn't editable in the rendered preview — title,
description, social cards, SEO. The app should expose a **context-sensitive
right-hand Inspector**, like the Pages inspector: the center pane is the live
preview (the canvas), the right inspector edits the metadata of the selected
page and, eventually, the selected element.

This is too large for one spec. It decomposes into three phases, each its own
spec → plan → build:

| Phase | Deliverable | Builds on |
|---|---|---|
| **1 (this spec)** | Inspector shell + page-level metadata (typed entries via #346 core; title/description for plain pages) | #346 core, `PageTitleEditor` |
| 2 | Social-card / SEO model — new frontmatter fields + `<meta>` rendering + OG image, surfaced in the inspector | #350 (JSON-LD), og-images skill |
| 3 | Selection-level inspector — overlay selection channel + per-element editing context | edit-overlay, apply-edit |

Phase 1 is the foundation and delivers the immediate ask: every page gets
editable metadata in a Pages-style inspector.

## Goal (Phase 1)

Move the typed content form (#346) from the main pane into a right-hand
`.inspector` panel, restore preview-on-select in the center, and add
title/description editing for plain (non-typed) **frontmatter** pages — so
selecting a frontmatter-bearing Page or Post shows its metadata in the inspector
while the preview renders in the center.

## Title model (clarified)

A page's **title is its `title` frontmatter** — the per-page token source. The
rendered `<title>` is composed from a **site-level tokenized title template**
(e.g. `{title} — {siteName}`) with the page's frontmatter title substituted. The
inspector edits **only the per-page `title` frontmatter**; the tokenized template
is a **main-site-settings** concern, edited there, **out of scope for the page
inspector** (a separate feature, likely landing with Phase 2 SEO). There is no
`.astro` `title="…"` attribute editing — titles are frontmatter, full stop.

## Decisions (locked in brainstorming)

- **Center = live preview** for the selected entry (navigates to its route).
- **Inspector auto-opens** on Page/Post selection; a toolbar toggle
  (`sidebar.right`) shows/hides it; the choice is remembered across selections.
- **Component/style files** keep the main-pane text editor; the inspector is
  hidden for them.
- **#346 reworked, not merged separately** — same branch/PR; the tested core
  stays, the main-pane form presentation is replaced by the inspector. The
  last-turn "form replaces main pane" routing is reverted to preview-on-select.
- **Single "Page" section** in Phase 1 — no tabs yet, but the inspector view is
  structured so a tab picker can be added for Phase 3's selection context.
- **Body field stays in the inspector** for typed entries in Phase 1 (otherwise
  a note's body would have no editor until Phase 3's overlay content editing).
  The "metadata in inspector / body in canvas" split is a Phase 3 refinement.

## Architecture

### Inspector shell (`SiteWindow`)

- Add `.inspector(isPresented: $inspectorShown)` to the detail pane.
- New state:
  - `inspectorContext: InspectorContext?` — `enum { case typed(TypedEntryEditorModel); case page(PageMetadataModel) }`.
  - `inspectorShown: Bool` — remembered user preference; applied on each Page/Post selection (auto-open) and toggled by the toolbar button.
- `applyNavigatorSelection` `.route` branch: resolve the navigator id via the
  content graph → file path. Navigate the preview to the route (center =
  preview), then set the inspector context by file kind:
  - `ContentTypeResolver` matches a content type → `inspectorContext = .typed(TypedEntryEditorModel(...))`, `inspectorShown = userPref`.
  - else a **frontmatter-bearing markdown page** (`.md`/`.mdx`/`.markdown`) → `inspectorContext = .page(PageMetadataModel(...))`, `inspectorShown = userPref`.
  - else (plain `.astro` template page, etc.) → `inspectorContext = nil`,
    inspector hidden — preview only. Plain `.astro` pages are **out of scope**
    for Phase 1 metadata editing (no YAML frontmatter to drive title).
- `.file` branch (components/styles/metadata): unchanged main-pane editor;
  `inspectorContext = nil`, inspector hidden. (Revert the #346/last-turn typed
  handling from this branch.)
- Remove the `.typed` case from the main-pane `ActiveEditor` enum and its
  `mainPaneContent`/`showsPaneModePicker` handling — the form is no longer a
  main-pane editor.
- Toolbar: a toggle `ToolbarItem` bound to `inspectorShown`, enabled only when
  `inspectorContext != nil`.
- ⌘S saves the active inspector model. Navigating away flushes it
  (`flushBeforeLeaving`, autosave + conflict check); a conflict aborts the
  switch, mirroring the existing `leaveCurrentEditor` contract.

### Inspector content (`PageInspectorView`, App)

Takes the `InspectorContext` and renders:
- `.typed` → the descriptor form (the #346 `TypedEntryEditorView`, trimmed of its
  full-pane header since the inspector supplies panel chrome; keeps a compact
  dirty/Save affordance and the per-`Kind` controls).
- `.page` → a small form with **Title** and **Description** fields bound to the
  `PageMetadataModel`.

### Generic page metadata (`PageMetadataEditor` Core, `PageMetadataModel` App)

For frontmatter-bearing markdown pages that are **not** typed content (no
`ContentTypeResolver` match) — title + description only.

- **`PageMetadataEditor`** (Core, pure, no I/O): `read(_ contents: String) -> PageMetadata`
  and `write(_ metadata: PageMetadata, into contents: String) -> String`, where
  `PageMetadata` carries `title: String` and `description: String`. Both read and
  write go through `FrontmatterDocument` (reused; round-trip-safe — unknown keys
  and body preserved verbatim; only the `title`/`description` keys are touched, and
  only when changed). No `.astro` attribute path — `.astro` pages are out of
  scope (see routing above), so `PageTitleEditor` is **not** modified.
- **`PageMetadataModel`** (App, `@MainActor @Observable`): mirrors
  `TypedEntryEditorModel` — `load()`/`save()`/`flushBeforeLeaving()`/
  `checkExternalChange()` over `FileDocumentIO`, title/description bindings,
  per-edit git commit (`anglesite: edit page <slug>`) via
  `NativeContentOperations.processGitCommit`.

## Data flow

```
select Page/Post in navigator
  → applyNavigatorSelection(.route)
  → look up content graph → filePath
  → preview.navigate(toRoute:)                    // center = preview, always
  → classify file:
       ContentTypeResolver match  → .typed(TypedEntryEditorModel), show inspector
       markdown page (no match)   → .page(PageMetadataModel),       show inspector
       plain .astro / other       → inspectorContext = nil,         hide inspector
  → inspectorShown = userPref (when context != nil)   // auto-open
  → PageInspectorView renders the matching form
  → edit field → Save → write file → git commit → preview HMR refresh
```

## Error handling

- **Load failure / unreadable file:** surfaced via the model's load-error state,
  same as `FileEditorModel`/`TypedEntryEditorModel`.
- **External change while editing:** reuse the conflict path
  (`checkExternalChange`, keep-mine / reload).
- **Round-trip safety:** all metadata writes go through `FrontmatterDocument`
  (unknown keys + body preserved verbatim; only changed keys re-rendered).
- **Commit failure:** best-effort; the file is still written, matching
  `processGitCommit` semantics.

## Testing

- **`PageMetadataEditor` (Core, unit):** read title + description from
  frontmatter; write changed title/description (round-trip identity when
  unchanged, unknown keys + body preserved verbatim, only changed keys
  re-rendered); empty/missing fields default to "".
- App-target inspector shell/views are not CI-testable (hosted app) → validated
  by `swift build` + in-app smoke: select a note → typed form in the right
  inspector with preview in the center; select a plain page → title/description
  in the inspector; edit + save → disk + git commit + preview refresh; select a
  component → main-pane text editor, inspector hidden; toolbar toggle hides/shows
  the inspector and the choice persists across selections.

## Files

New:
- `Sources/AnglesiteCore/PageMetadataEditor.swift`
- `Sources/AnglesiteApp/PageMetadataModel.swift`
- `Sources/AnglesiteApp/PageInspectorView.swift`
- `Tests/AnglesiteCoreTests/PageMetadataEditorTests.swift`

Modified:
- `Sources/AnglesiteApp/SiteWindow.swift` — inspector shell, routing rework,
  toolbar toggle, remove `.typed` main-pane case.
- `Sources/AnglesiteApp/TypedEntryEditorView.swift` — trim full-pane header for
  inspector hosting (becomes the typed branch of `PageInspectorView`).

`PageTitleEditor.swift` is **not** modified (no `.astro` attribute editing).

## Scope discipline (out of scope)

- The **site-level tokenized title template** (e.g. `{title} — {siteName}`) and
  its render-time substitution — a main-site-settings feature, likely Phase 2.
- **Plain `.astro` template page** metadata editing (no frontmatter to drive it).
- Social-card / OG / SEO / canonical fields and their `<meta>` rendering (Phase 2).
- Selection-level inspector + the overlay selection channel (Phase 3).
- Inspector tabs / multiple sections (Phase 3).
- Editing typed-entry body in the preview canvas (Phase 3) — body stays in the
  inspector form for now.
