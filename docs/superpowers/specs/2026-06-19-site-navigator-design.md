# Site Navigator — design

**Date:** 2026-06-19
**Status:** Approved (brainstorm)

## Summary

Add an Xcode-Project-Navigator-style sidebar to each site window. It presents
the site's content as curated semantic groups (Pages, Posts, Components, Styles,
Metadata). Selecting a page navigates the live preview; selecting a non-page file
opens it in an inline text editor that replaces the preview in the main pane. The
editor is fronted by a routing seam so file-specific editors (a metadata form
editor especially) can replace the generic text editor later without touching
call sites.

## Motivation

Today a site window is a preview (WKWebView) plus an optional chat panel — there
is no way to browse a site's structure or jump directly to a page, component, or
metadata file. Owners expect a navigator like Xcode's: a stable left sidebar that
lists the site's parts and lets them open any one for editing.

## Goals (v1)

- A persistent, collapsible left sidebar listing the site's content in five
  curated groups.
- Selecting a **page/post** navigates the preview to that route.
- Selecting a **non-page file** (component, style, metadata) opens it in an
  inline text editor that replaces the preview in the main pane.
- The text editor uses explicit save (⌘S), shows dirty state, and guards against
  external changes (other tools — chat, edit overlay, Claude Code CLI — write the
  same files).
- An editor-routing seam (`EditorKind`) so file-specific editors slot in later.

## Non-goals (deferred)

- File-specific editors (metadata form editor, etc.) — the seam is built, only
  `.text` is implemented.
- Creating / renaming / deleting / moving files from the tree. v1 is **read +
  edit-existing only**.
- Multi-file tabs, split editor+preview, drag-to-reorder.

## Architecture

### Layout

Wrap the current `siteUI(for:)` content in a `NavigationSplitView`:

- **Sidebar** — the navigator (`SiteNavigatorView`).
- **Detail** — the existing main-pane + chat panel + deploy/backup drawers,
  unchanged except that the main pane gains a *mode* (below).

`NavigationSplitView` supplies the standard collapsible sidebar and toolbar
toggle. Sidebar visibility/width persist with `@SceneStorage` (per window) so the
choice survives relaunch and state restoration.

### Main-pane mode

The main pane is currently always the preview. Introduce:

```swift
enum MainPaneMode: Equatable {
    case preview
    case editor(FileRef)
}
```

held as `@State` in `SiteWindow`.

- Selecting a **page/post** → `mode = .preview`, then
  `preview.navigate(toRoute:)` (or `preview.clearRoute()` for the site root).
- Selecting a **non-page file** → `mode = .editor(file)`. The editor **replaces**
  the preview (chosen layout: option A). A small segmented control at the top of
  the main pane toggles `Preview | Editor` so the user can flip back without
  losing the open file.

`FileRef` is a small value type (`Sendable`, `Equatable`, `Identifiable`)
identifying a file by absolute URL plus its group and display name.

### The tree (curated groups)

Five disclosure groups, in order:

| Group       | Source                                              |
|-------------|-----------------------------------------------------|
| Pages       | `SiteContentGraph.Page` (title + route)             |
| Posts       | `SiteContentGraph.Post` (title, draft, date)        |
| Components  | filesystem: `Source/src/layouts`, `Source/src/components` (if present) |
| Styles      | filesystem: `Source/src/styles`                     |
| Metadata    | filesystem: `Config/`, the package `Info.plist` marker |

Excluded everywhere: `node_modules`, build output (`dist`/`.astro`), lockfiles,
VCS dirs. Empty groups are hidden.

Pages/Posts are semantic (from the content graph); the other three are raw file
listings rooted via `AnglesitePackage` (`sourceURL`, `Config/`).

### Editor + routing seam

```swift
enum EditorKind { case text /* future: .metadataForm, ... */ }
func editorKind(for file: FileRef) -> EditorKind   // v1: always .text
```

`MainPaneEditorView` switches on the kind. v1 implements only the text path; the
function and enum exist so adding `.metadataForm` later is a one-line mapping plus
a new view — no call-site churn.

Text editor behavior (chosen: option C — explicit save + external-change aware):

- Loads file contents into a buffer; tracks `isDirty`.
- ⌘S writes the buffer to disk. Dirty state shown in both the tree row and the
  main pane.
- Watches the open file for external modification (mtime/content). On an external
  change while the buffer is clean → reload silently; while dirty → warn and let
  the user choose **Keep my changes** or **Reload from disk**. Never silently
  clobbers either side.
- A save writes to disk → existing dev-server file-watch rebuilds → the preview
  reflects the change next time the user switches to Preview.

### Where the logic lives

Testable, App-independent types in `AnglesiteCore` (CI-runnable via `swift test`):

- **`SiteFileTree`** — given an `AnglesitePackage`, scans the filesystem-backed
  groups (Components/Styles/Metadata) into grouped `FileRef`s. `FileManager`
  injected; exclusion rules unit-tested.
- **`FileDocumentModel`** — load / dirty / save state machine plus
  external-change detection. The reconcile logic (clean→reload, dirty→prompt) is
  the core under test.

App-target glue (not CI-tested through a hosted app target, kept thin):

- **`SiteNavigatorModel`** (`@MainActor @Observable`) — merges content-graph
  pages/posts with the `SiteFileTree` scan into the grouped tree, owns the
  selection, and drives `MainPaneMode`. Refreshes on content-graph changes and on
  filesystem changes.
- **`SiteNavigatorView`** / **`MainPaneEditorView`** — SwiftUI.

### Content-graph observation

`SiteContentGraph`'s change handler is **single-subscriber by design** and is
already taken by the Spotlight indexer (`ContentSpotlightIndexer`). The navigator
needs independent live updates, so:

**Decision:** add an `AsyncStream`-based broadcast to `SiteContentGraph`
(mirroring `SiteStore.changeStream()`), allowing multiple independent observers
(indexer + navigator). The existing single-subscriber handler stays for
backward compatibility, or the indexer migrates to the stream — to be settled in
the plan. The navigator consumes the stream to refresh Pages/Posts; it watches
the filesystem (or piggybacks on the dev-server watch) to refresh the other three
groups.

## Data flow

1. Window opens → `SiteNavigatorModel` reads a `SiteContentGraph` snapshot
   (Pages/Posts) and runs a `SiteFileTree` scan (Components/Styles/Metadata),
   builds the grouped tree.
2. User selects a row:
   - page/post → `mode = .preview` + `preview.navigate(toRoute:)`.
   - file → `mode = .editor(file)`; `FileDocumentModel` loads it.
3. User edits + ⌘S → `FileDocumentModel` writes to disk → dev-server file-watch →
   rebuild → preview updated.
4. External tool writes an open file → `FileDocumentModel` detects it → silent
   reload (clean) or prompt (dirty).
5. Content/filesystem changes → model refreshes the affected group(s).

## Error handling

- Unreadable / vanished file on open → editor shows an inline error state with a
  "Reveal in Finder" affordance; selection does not crash the window.
- Save failure (permissions, MAS sandbox grant lapsed) → non-destructive error;
  buffer stays dirty; message surfaced (and logged to the debug pane per the
  "logs are sacred" rule).
- Empty / missing groups (e.g. no `Config/` yet) → group hidden, not an error.
- MAS: all file reads/writes occur within the window's existing security-scoped
  grant (`scopedURL`); no new entitlement.

## Testing

- `SiteFileTreeTests` — grouping, exclusion of plumbing, empty-dir handling,
  package roots resolved via `AnglesitePackage`.
- `FileDocumentModelTests` — dirty tracking, save writes bytes, external-change
  reconcile (clean→reload, dirty→prompt outcomes).
- `SiteContentGraph` broadcast — multiple subscribers each receive change
  notifications; emit-on-real-mutation semantics preserved.

## Open questions for the plan

- Whether `ContentSpotlightIndexer` migrates to the new broadcast stream or the
  single-subscriber handler is kept alongside it.
- Exact filesystem-watch mechanism for the non-content groups (dedicated watcher
  vs. reuse of the dev-server watch signal).
