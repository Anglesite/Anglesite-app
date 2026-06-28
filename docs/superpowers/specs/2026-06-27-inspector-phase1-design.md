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
title/description editing for plain (non-typed) pages — so selecting **any**
Page or Post shows its metadata in the inspector while the preview renders in the
center.

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
  content graph → file path.
  - If `ContentTypeResolver` matches a content type → `inspectorContext = .typed(TypedEntryEditorModel(...))`.
  - Else (plain page) → `inspectorContext = .page(PageMetadataModel(...))`.
  - Either way: navigate the preview to the entry's route (center = preview) and
    set `inspectorShown = userPref`.
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

- **`PageMetadataEditor`** (Core, pure, no I/O): `read(_ contents: String, fileExtension: String) -> PageMetadata` and `write(_ metadata: PageMetadata, into contents: String, fileExtension: String) -> Result<String, Error>`, where `PageMetadata` carries `title: String` and `description: String`.
  - **Markdown** (`.md`/`.mdx`/`.markdown`): read/write `title` + `description`
    frontmatter via `FrontmatterDocument` (reused; round-trip-safe).
  - **`.astro`/`.html`**: rewrite the first literal `title="…"` / `description="…"`
    attribute via the existing `PageTitleEditor` pattern (extend it with a
    description-attribute path). A dynamic (non-literal) attribute → report
    "no editable location" for that field; the field renders disabled with an
    explanatory caption.
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
  → ContentTypeResolver: typed?  ┐
       yes → inspectorContext = .typed(TypedEntryEditorModel)
       no  → inspectorContext = .page(PageMetadataModel)
  → preview.navigate(toRoute:)            // center = preview
  → inspectorShown = userPref             // auto-open
  → PageInspectorView renders the matching form
  → edit field → Save → write file → git commit → preview HMR refresh
```

## Error handling

- **Load failure / unreadable file:** surfaced via the model's load-error state,
  same as `FileEditorModel`/`TypedEntryEditorModel`.
- **External change while editing:** reuse the conflict path
  (`checkExternalChange`, keep-mine / reload).
- **Non-literal `.astro` title/description:** the field is shown disabled with a
  caption ("This page's title isn't a literal value — edit it in the source");
  no write is attempted.
- **Round-trip safety:** markdown metadata writes go through `FrontmatterDocument`
  (unknown keys + body preserved verbatim); `.astro` rewrites touch only the
  matched attribute.
- **Commit failure:** best-effort; the file is still written, matching
  `processGitCommit` semantics.

## Testing

- **`PageMetadataEditor` (Core, unit):** markdown read/write of title +
  description (round-trip, unknown keys preserved); `.astro` literal-attribute
  rewrite for title and description; dynamic-attribute → no-edit result;
  unaffected content preserved verbatim.
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
- `Sources/AnglesiteCore/PageTitleEditor.swift` — add the description-attribute
  rewrite path (if not folded into `PageMetadataEditor`).

## Scope discipline (out of scope)

- Social-card / OG / SEO / canonical fields and their `<meta>` rendering (Phase 2).
- Selection-level inspector + the overlay selection channel (Phase 3).
- Inspector tabs / multiple sections (Phase 3).
- Editing typed-entry body in the preview canvas (Phase 3) — body stays in the
  inspector form for now.
