# Inline page/post re-titling in the project navigator

**Date:** 2026-06-23
**Status:** Approved (design)

## Problem

In the project navigator (the Xcode-style sidebar that lists a site's pages and
posts), there is no way to change a page's displayed name. The user wants to
re-title a page by control-clicking its name and editing it in place — the same
interaction Finder offers for renaming a file.

The navigator displays each item's **title**, not its filename. For pages that
title comes from the layout invocation's `title="…"` attribute; for blog posts it
comes from YAML frontmatter `title:`. So "re-title" means *edit the title*, not
*rename the file*.

## Decisions

1. **Title only.** Editing changes only the title. The file path and the page's
   URL/route are never touched. (Renaming the file/route is a separate, future
   feature.)
2. **Inline edit in place.** Control-click → context-menu **Rename**; pressing
   **Return** on the selected renamable row also begins editing. The row's text
   becomes an editable `TextField` in the sidebar. Return / focus-loss commits,
   Esc cancels. This mirrors Finder.
3. **Write where the title lives** (per file type):
   - `.md` / `.mdx` / `.markdown` (posts) → YAML frontmatter `title:`.
   - `.astro` / `.html` (pages) → the first `title="…"` / `title='…'` attribute.

These reflect the real template: pages are `.astro` files that pass
`title="…"` as a prop to `BaseLayout` (the `---` fence in an `.astro` file is a
JavaScript component script, **not** YAML — writing YAML `title:` there would be
invalid and would not change the rendered `<title>`), while blog posts are `.md`
files in `src/content/blog/` with real YAML frontmatter.

## Scope

**In scope:** Page rows and Post rows in the navigator (content-graph–backed
items that carry a title).

**Out of scope:**

- Component / Style / Metadata file rows — these are plain files, not titled
  content. A general "rename file" feature is future work.
- An `.astro` / `.html` page with **no** `title=` attribute and no usable
  frontmatter — there is no safe place to inject a title prop, so its Rename
  affordance is disabled (not renamable).
- Changing the filename, route, or URL.
- Routing through the MCP/plugin server — this is a local file edit and runs
  entirely native.

## Components

### `PageTitleEditor` (AnglesiteCore) — pure, no I/O

The testable core. Given file contents, the file extension, and a new title,
returns the rewritten contents or a typed error. No filesystem access.

```swift
enum PageTitleEditor {
    enum RewriteError: Error, Equatable {
        case emptyTitle          // new title is empty/whitespace
        case noEditableLocation  // astro/html with no title= attribute, etc.
    }

    static func rewrite(
        contents: String,
        fileExtension: String,
        newTitle: String
    ) -> Result<String, RewriteError>
}
```

Behavior:

- **Markdown family** (`md`, `mdx`, `markdown`): locate the leading `---` YAML
  block. Replace the existing `title:` line, or insert a `title:` field if the
  block exists without one, or synthesize a `---` block at the top of the file
  if none exists. The value is YAML-quoted: wrapped in double quotes with `"` and
  `\` escaped.
- **Astro / HTML** (`astro`, `html`): find the first `title=` attribute
  (double- or single-quoted) and replace its value, HTML-escaping `"`, `&`, and
  `<`. If no `title=` attribute is present → `.noEditableLocation`.
- Empty/whitespace `newTitle` → `.emptyTitle` (for any file type).

Escaping per format ensures quotes and special characters in a title cannot
corrupt the file.

### Rename flow — wired into `SiteNavigatorModel`

The model already resolves navigator items against `SiteContentGraph` and the
filesystem, so it can map a row id to a page/post and its `filePath` +
extension.

```swift
// Whether a row may be renamed (drives context-menu / Return availability).
// False for non-titled file rows, and for astro/html pages with no title= attr.
func canRename(_ id: String) -> Bool

// Perform the rename: load → rewrite → save → git commit → graph refresh.
func rename(_ id: String, to newTitle: String) async
```

`rename` steps:

1. Resolve the item → file URL + extension. Bail (no-op) if not renamable.
2. `FileDocumentIO.load(url)` to read current contents.
3. `PageTitleEditor.rewrite(contents:fileExtension:newTitle:)`.
   - `.emptyTitle` → abort, keep original title, clear edit state.
   - `.noEditableLocation` → abort, surface an alert (should be pre-empted by
     `canRename`, but handled defensively).
4. `FileDocumentIO.save(newContents, to: url)`.
5. Git commit via the **same injected `gitCommit` closure** that
   `NativeContentOperations` uses, message `Rename title to "<newTitle>"`.
6. Trigger a content-graph refresh for the affected file so the row re-renders
   with the new title.

Any load/save/git failure surfaces an alert and leaves the original title
intact. File I/O and the git closure are injectable so the flow is testable.

### Navigator UI (`SiteNavigatorView` + `SiteNavigatorModel`)

- `SiteNavigatorModel` gains:
  - `editingItemID: String?` — which row is in edit mode.
  - `draftTitle: String` — the in-progress text.
  - A `@FocusState`-driven focus on the `TextField` (held in the view).
- A row renders an inline `TextField(text: $draftTitle)` when
  `editingItemID == item.id`, otherwise the existing `Text`. `onSubmit` →
  `await model.rename(id, to: draftTitle)`; Esc / focus loss with no submit →
  cancel (clear `editingItemID`).
- `.contextMenu { Button("Rename") { model.beginEditing(id) } }` shown only when
  `model.canRename(id)`.
- A keyboard path (`Return` on the selected renamable row) calls
  `beginEditing`. (Double-click may also begin editing; optional, since single
  click already selects + navigates the preview.)

## Data flow

```
control-click / Return on row
  → model.beginEditing(id)        (editingItemID = id, draftTitle = current)
  → inline TextField
  → onSubmit
  → model.rename(id, to: draft)
       load → PageTitleEditor.rewrite → save → git commit → graph refresh
  → navigator rebuilds section with new title
  → editingItemID = nil
```

## Error handling

| Situation | Behavior |
|---|---|
| Empty / whitespace title | No write; revert to original; clear edit state |
| `.astro`/`.html` with no `title=` attr | Not renamable — Rename affordance disabled |
| File load / save failure | Alert; original title preserved |
| Git commit failure | Alert; file change kept, surfaced to user (consistent with existing native ops) |
| Special chars / quotes in title | Escaped per format (YAML quote / HTML attr escape) |

## Testing

**`PageTitleEditor` unit tests (Swift Testing `@Test`):**

- Markdown with an existing `title:` → value replaced.
- Markdown with frontmatter but no `title:` → field inserted.
- Markdown with no frontmatter → `---` block synthesized at top.
- Astro with a double-quoted `title="…"` → value replaced.
- Astro with a single-quoted `title='…'` → value replaced.
- Astro / HTML with no `title=` attribute → `.noEditableLocation`.
- HTML with a `title="…"` attribute → value replaced.
- Title containing quotes / `&` / `<` → correctly escaped per format.
- Empty / whitespace title → `.emptyTitle`.

**Model-level rename test:** with injected file I/O and `gitCommit` closure,
verify the full load → rewrite → save → commit → refresh path runs and the
graph/navigator reflect the new title; verify failures preserve the original
title.

## Non-goals / future work

- Renaming the file / changing the route or URL.
- Inline rename of component / style / metadata files.
- Re-titling via a sheet/dialog (we chose inline).

## Platform notes

No new entitlements: the file editor already writes `Source/` files through
`FileDocumentIO`, so write access (incl. the MAS security-scoped grant) is
already in place. The feature is MAS-safe and routes no work through the plugin.
