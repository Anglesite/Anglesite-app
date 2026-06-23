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
- An `.astro` / `.html` page with **no** `title=` attribute — there is no safe
  place to inject a title prop, so renaming is **rejected at commit with an
  alert** (no file change). It is not pre-disabled: pre-checking would require
  reading every page file on each navigator refresh, so the check happens once,
  on demand, when the user actually commits a rename.
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

### `NavigatorRenameService` (AnglesiteCore) — the testable flow

The load → rewrite → save → commit pipeline lives in AnglesiteCore (not the
app-target model) because `swift test` covers Core but not the app target — the
project's established pattern (cf. `TokenOnboarding`). File I/O and the git
closure are injected so the flow is fully unit-testable.

```swift
public struct NavigatorRenameService {
    public enum RenameError: Error, Equatable {
        case emptyTitle          // from PageTitleEditor
        case noEditableLocation  // from PageTitleEditor
        case io(String)          // load/save failure
    }
    public typealias GitCommit = NativeContentOperations.GitCommit
        // (_ projectRoot: URL, _ relPath: String, _ message: String) async -> String?

    public init(
        loadContents: @escaping @Sendable (URL) throws -> String = { try FileDocumentIO.load($0).contents },
        saveContents: @escaping @Sendable (String, URL) throws -> Void = { try FileDocumentIO.save($0, to: $1) },
        gitCommit: @escaping GitCommit = NativeContentOperations.processGitCommit
    )

    // Returns the trimmed new title on success.
    public func rename(
        fileURL: URL,
        fileExtension: String,
        projectRoot: URL,
        relativePath: String,
        newTitle: String
    ) async -> Result<String, RenameError>
}
```

`rename` steps:

1. `loadContents(fileURL)` → current contents (`.io` on failure).
2. `PageTitleEditor.rewrite(contents:fileExtension:newTitle:)` — maps
   `.emptyTitle` / `.noEditableLocation` straight through to `RenameError`.
3. `saveContents(newContents, fileURL)` (`.io` on failure).
4. Git commit **best-effort** via the injected closure, message
   `anglesite: rename title to "<newTitle>"`. A nil result (not a repo,
   rejecting hook, git missing) is ignored — the file is already saved and is
   the source of truth, so a failed commit never rolls back the title. This
   mirrors `NativeContentOperations`.
5. Return `.success(trimmedTitle)`.

### Rename glue — `SiteNavigatorModel` (app target, thin)

The model maps a row id to its `SiteContentGraph.Page`/`Post`, drives the
service, then reflects the result in the graph + UI. This glue is not unit-tested
(app target; consistent with other app glue).

```swift
// Section-based: true iff the id belongs to the Pages or Posts section.
// (The astro-no-title case is caught at commit, not pre-disabled — see spec.)
func canRename(_ id: String) -> Bool

func beginEditing(_ id: String)   // editingItemID = id; draftTitle = current title
func cancelEditing()              // editingItemID = nil
func commitEditing() async        // resolve id → page/post; run the service; update graph
```

`commitEditing` steps:

1. Resolve `editingItemID` → `SiteContentGraph.Page`/`Post` via the graph; bail
   if gone. Derive `fileURL = sourceDirectory.appending(filePath)`,
   `fileExtension` from `filePath`, `relativePath = filePath`,
   `projectRoot = sourceDirectory`.
2. `await renameService.rename(...)`.
3. On `.success(newTitle)`: build an updated `Page`/`Post` value (same id, same
   fields, `title = newTitle`) and `await graph.upsertPage(_:)` /
   `upsertPost(_:)`. The graph emits a change → the navigator's existing
   observer rebuilds `sections` with the new title.
4. On `.emptyTitle`: silently revert (no write happened).
5. On `.noEditableLocation` / `.io`: set `renameError` (an observable `String?`)
   so the view shows an `.alert`. Original title preserved.
6. Clear `editingItemID` in all cases.

**`sourceDirectory` plumbing.** `Page.filePath`/`Post.filePath` are relative to
the site's **source directory** (the `ContentScanner` project root), but
`start(siteID:siteRoot:)` currently receives `siteRoot = packageURL` (for
`SiteFileTree`, which adaptively resolves `Source/`). So `start` gains a
`sourceDirectory: URL` parameter, stored on the model and used to resolve
absolute file paths; the single call site in `SiteWindow` passes
`resolved.sourceDirectory`.

### Navigator UI (`SiteNavigatorView` + `SiteNavigatorModel`)

- `SiteNavigatorModel` gains:
  - `editingItemID: String?` — which row is in edit mode.
  - `draftTitle: String` — the in-progress text.
  - A `@FocusState`-driven focus on the `TextField` (held in the view).
- A row renders an inline `TextField(text: $model.draftTitle)` when
  `editingItemID == item.id`, otherwise the existing `Label`. `onSubmit` →
  `Task { await model.commitEditing() }`; Esc / focus loss → `cancelEditing()`.
- `.contextMenu { Button("Rename") { model.beginEditing(item.id) } }` shown only
  when `model.canRename(item.id)`.
- A keyboard path (`Return` on the selected renamable row) calls
  `beginEditing`. (Double-click may also begin editing; optional, since single
  click already selects + navigates the preview.)
- `.alert` bound to `model.renameError` surfaces `.noEditableLocation` / `.io`
  failures.

## Data flow

```
control-click / Return on row
  → model.beginEditing(id)         (editingItemID = id, draftTitle = current)
  → inline TextField
  → onSubmit → model.commitEditing()
       resolve id → page/post
       → renameService.rename(...)  (load → rewrite → save → best-effort commit)
       → graph.upsertPage/Post(title: new)  → emits change
  → navigator's observer rebuilds sections with new title
  → editingItemID = nil
```

## Error handling

| Situation | Behavior |
|---|---|
| Empty / whitespace title | No write; revert to original; clear edit state |
| `.astro`/`.html` with no `title=` attr | Rename rejected at commit with an alert; no file change |
| File load / save failure | Alert (`.io`); original title preserved |
| Git commit failure | Best-effort; ignored. File change kept (consistent with `NativeContentOperations`) |
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

**`NavigatorRenameService` tests (Swift Testing `@Test`, AnglesiteCore):** with
injected `loadContents` / `saveContents` / `gitCommit`:

- Success (markdown): saved contents carry the new frontmatter title; result is
  `.success(trimmedTitle)`; git closure invoked with the right relPath/message.
- `.emptyTitle` propagates; `saveContents` is **not** called.
- `.noEditableLocation` (astro, no attr) propagates; `saveContents` not called.
- `saveContents` throws → `.io`.
- Git commit returns nil → still `.success` (best-effort), and the save still
  happened.

The `SiteNavigatorModel` glue (graph upsert, edit state) is app-target and not
unit-tested, consistent with other app glue — it is exercised by the build.

## Non-goals / future work

- Renaming the file / changing the route or URL.
- Inline rename of component / style / metadata files.
- Re-titling via a sheet/dialog (we chose inline).

## Platform notes

No new entitlements: the file editor already writes `Source/` files through
`FileDocumentIO`, so write access (incl. the MAS security-scoped grant) is
already in place. The feature is MAS-safe and routes no work through the plugin.
