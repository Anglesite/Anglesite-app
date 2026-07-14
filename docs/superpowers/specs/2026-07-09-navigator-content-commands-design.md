# Navigator content commands: Delete, Duplicate, New Post…, New Component…

**Issue:** [#516](https://github.com/Anglesite/Anglesite-app/issues/516) · **Related:** #518 (menu bar completeness), #530 (redirect offers, future), #531 (quick-capture, future), #496 (Component Editor epic, future)

## Problem

The navigator context menu only has **Rename** (`SiteNavigatorView.swift:127-131`), and `NewContentActions` (`FocusedSite.swift:9-12`) only wires up New Page / New Collection to the File menu. Four content-management verbs are missing:

- **Delete Page/Post…** — remove from the working tree via git, with confirmation
- **Duplicate Page/Post** — copy in place
- **New Post…** — the navigator already displays a Posts group (built from `SiteContentGraph.Post` in `NavigatorTree.swift:52-54`), and `NativeContentOperations.createPost` already exists as a callable service, but nothing in the UI triggers it
- **New Component…** — pairs with the Component Editor epic (#496), which is still "approved design, pre-implementation." This PR ships a minimal blank-file scaffold; semantic editing arrives later with #496.

The maintainer has flagged **New Post…** as the highest-value single action for a link-blogger archetype (high-frequency posting, decades-deep archive).

## Existing precedent this design follows

Every current mutation (`createPage`, `createPost`, `createTyped`, rename) is a synchronous, self-committing operation: validate → mutate the filesystem → `gitCommit` inline (`NativeContentOperations.swift:40-164`, `NavigatorRenameService.swift:30-56`). `BackupModel` is a separate, manual, user-triggered full-repo commit+push and is **not** currently in the mutation path for any per-op change.

The issue text says to "let Backup commit" for delete/duplicate — this design intentionally **does not** follow that wording. It keeps the existing auto-commit-per-op precedent instead, so the working tree never has to explain itself to the user, and so Delete/Duplicate/New Post/New Component behave identically to today's New Page and Rename. `BackupModel` remains what it is: a manual full-repo commit+push, unaffected by this change.

Delete also follows an existing precedent this issue's own wording didn't anticipate: `ProjectCleanupModel.delete` (dead-asset Cleanup) already established a pure `git rm` + commit deletion via `NativeContentOperations.processGitDelete`, with an explicit design comment that it deliberately never falls back to a non-git raw delete. Delete Page/Post reuses that exact function rather than introducing `FileManager.trashItem`/Trash — one delete mechanism across the app, consistent with "git is the source of truth."

## Architecture

Four new operations on `AnglesiteCore/NativeContentOperations`, each following the exact shape of `createPage`/`createPost`:

- `deleteContent(target:)` — `git rm` + commit via `NativeContentOperations.processGitDelete` (the same function `ProjectCleanupModel` already uses for dead-asset deletion). No Trash — git history is the sole undo path.
- `duplicatePage(from:)` / `duplicatePost(from:)` — read the source file, derive a `"<Title> Copy"` title and a `-copy`/`-copy-2`/… slug via the existing `ContentScaffold.slugify` collision loop, write the new file, commit.
- `createComponent(name:)` — mirrors `createTyped`: writes a minimal blank `.astro` file into `src/components/`, with the same collision handling, commits. No AI-assisted description step (not applicable to a blank scaffold).

Model layer:

- `SiteWindowModel` adds `newPostPresented` / `newComponentPresented` (mirroring `newPagePresented`), a `deleteConfirmation: NavigatorItem?` published property driving a confirmation dialog, and a `duplicate(id:)` method.
- `SiteNavigatorModel` adds `canDelete(_:)` / `canDuplicate(_:)`, sharing `canRename(_:)`'s exact gating: `true` only for `.route` targets (pages/posts), `false` for everything else — the site root, folders, `.metadata` items, and file-backed rows including components. A component created via New Component… can't be deleted or duplicated from the Navigator in this scope (Rename can't touch it either); that's intentional, not a gap.
- `FocusedSite.swift`: `NewContentActions` gains `newPost` / `newComponent` closures (published the same way as `newPage`/`newCollection` in `SiteWindow.swift:90-93`). A new `NavigatorSelectionActions` focused value carries `delete` / `duplicate` closures, `nil` when the current selection isn't deletable/duplicable — this is what lets the File menu items enable/disable correctly without the menu needing to know navigator internals.

UI surfaces:

- Navigator context menu (`SiteNavigatorView.swift`, alongside the existing Rename item): Delete, Duplicate.
- Menu bar: File ▸ New submenu (`NewContentCommands`) gains Post…/Component… entries alongside the existing Page…/Collection…; a new `CommandGroup(after: .pasteboard)` in the **Edit menu** adds Delete/Duplicate (⌘⌫ / ⌘D), acting on the current navigator selection — matching where macOS apps conventionally place selection-scoped Delete/Duplicate, next to Cut/Copy/Paste rather than under File. Both menu-bar entries and the context-menu entries share the same `SiteNavigatorModel.canDelete`/`canDuplicate` gating and the same `SiteWindowModel` action methods, so behavior is identical regardless of entry point.

## Data flow & error handling

**Delete**: context-menu/Edit-menu action → `SiteNavigatorModel.canDelete(id)` gates availability → `SiteWindowModel.deleteConfirmation = item` → `SiteNavigatorView`/`SiteWindow` shows a `.confirmationDialog` → on confirm, `SiteWindowModel.confirmDelete()` resolves the `NavigatorItem` to its page/post record and calls `contentCreation.deleteContent(siteID:relativePath:)`, which delegates to `processGitDelete` (`git rm` + commit). If that fails (dirty tree, no HEAD copy, rejecting hook), nothing on disk changes — `processGitDelete` refuses up front rather than leaving a partial state — and an alert surfaces the reason. Any editor/inspector state open on the file being deleted is discarded before the delete call (to prevent a suspended flush from resurrecting a file git just removed) and restored if the delete fails, since a failed delete never touched the file. On success, the navigator tree rebuilds via the existing `SiteContentGraph`/`SiteFileTree.scan` path and selection clears.

**Duplicate**: no confirmation (non-destructive). Resolves the source `FileRef`, calls `duplicatePage`/`duplicatePost`, then sets the navigator selection to the newly created item so the user can immediately see and rename it. The slug-suffix collision loop reuses `ContentScaffold`'s existing logic, bounded and consistent with page creation.

**New Post…/New Component…**: identical shape to the existing `NewPageSheet` → `createPage` flow. A small sheet collects the title (Post) or name (Component); same validation/collision/failure UI `NewPageSheet` already provides.

**Future integration point (not implemented here)**: `deleteContent`/`duplicatePage`/`duplicatePost` return the affected route(s) — old route for delete, old+new for duplicate — so #530's redirect-offer flow can subscribe to that result later without a signature change.

## Testing

- `NativeContentOperations` (AnglesiteCoreTests, Swift Testing): one test per new op against a scratch git-repo fixture, mirroring the existing `createPage`/`createPost` tests 1:1 — `deleteContent` (file gone from `Source/`, commit made), `duplicatePage`/`duplicatePost` collision-suffix tests (`-copy`, `-copy-2`), `createComponent` (blank file written to `src/components/`, collision handling reused from `createTyped`).
- `SiteNavigatorModel`: `canDelete`/`canDuplicate` gating tests (root/folder/`.metadata` excluded; page/post/component included), mirroring existing `canRename` tests.
- `SiteWindowModel`: confirmation-flow and selection-after-duplicate tests, following the existing `newPagePresented`/`createPage` sheet-flow test patterns.
- No new hosted-app (`xcodebuild test`) coverage needed — per CLAUDE.md, this logic lives in testable `AnglesiteCore`/`AnglesiteApp` model types, not view code, so `swift test` covers it on CI.
- Manual GUI verification before calling this done: open a site, exercise Delete (confirmation dialog, git-tracked removal, tree update), Duplicate, New Post…, New Component… end to end in the running app.

## Non-goals

- Redirect-offer wiring (#530) — extension point only (routes returned from the ops above), not implemented here.
- Quick-capture / link-post prefill (#531) — New Post… is a plain title-entry sheet, no URL/`og:` metadata pull.
- Semantic `.astro` editing (#496) — New Component… scaffolds a blank file opened in the existing plain `TextEditor`; no compiler-aware editing.
- Bulk delete/duplicate (multi-selection) — single-item only, matching today's single-selection Rename.
