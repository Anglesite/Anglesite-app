# Dead Asset & Orphaned Content Detection

**Date:** 2026-07-07
**Status:** Approved design, pre-implementation
**Related:** #310 (feature request), #140 (deferred `usedOnPages` reverse reference), #312 (internal link assistant — `LinkGraph`/orphan-page precedent)

## 1. Summary

Adds an on-demand "Project Cleanup" scan that detects three kinds of dead weight in a site's
`Source/` tree — unused Astro components/layouts, unused images, and orphaned pages — and
surfaces them in a new Navigator sidebar section with **Open / Ignore / Delete** actions. Delete
is git-tracked (`git rm` + commit), so it doubles as the archive/undo story without any new
storage mechanism.

This directly completes a stub that has existed since #140: `SiteContentGraph.Image.usedOnPages`
has always been hardcoded to `[]` (`ContentScanner.swift:156`, "reverse … deferred (#140)") because
the reverse-reference computation was never built. It also aggregates `LinkGraph.orphanPages`
(already computed today, but only surfaced per-page in the Related Pages panel) into a
project-wide view for the first time.

## 2. Scope

**In scope (v1):**

- Unused `.astro` files under `src/components/` and `src/layouts/`
- Unused images under `public/images/**` (the exact set `SiteContentGraph.Image` already models)
- Orphaned pages (zero inbound internal links, excluding the index page) — reuses
  `LinkGraph.orphanPages` unchanged
- Open / Ignore / Delete actions on any candidate, from a new Navigator "Cleanup" section
- On-demand scan only, triggered by an explicit user action

**Out of scope (v1) — see §8 for rationale:**

- Draft-aged content, duplicate-content detection, empty-collection detection
- Fonts, icons, or any asset outside `public/images/**`
- Generic utility modules (`src/utils/**/*.ts`, `SiteKnowledgeIndex.Document.Kind.script`)
- Continuous/file-watch-driven scanning
- A separate "Archive" action distinct from git-tracked delete

## 3. Detection engine (`AnglesiteCore`)

Two new pure, fixture-testable types, following the existing `ContentScanner`/`LinkGraph` shape
(enums, no actors, no I/O beyond reading the file tree once).

### 3.1 `DeadAssetScanner`

Walks the project's source files and extracts four kinds of reference from each, using the same
compiled-once-`NSRegularExpression` style as `SiteKnowledgeIndex.internalLinks`:

1. **ES imports** — `import ... from "<path>"` — the primary signal for component/layout usage.
2. **`href=`/`src=` attributes** — reuses `SiteKnowledgeIndex`'s existing extraction approach, but
   *unlike* `LinkGraph.normalizeRoute` (which discards relative `./`/`../` links because it has no
   directory context at that call site), this resolves relative paths against **the referencing
   file's own directory** — that context is available here and is exactly what import/asset
   resolution needs.
3. **Frontmatter `layout:` field** — already parsed by `Frontmatter.parse`; this is just reading a
   field the existing scanner doesn't look at.
4. **`Astro.glob('<pattern>')` calls** — resolves the glob's directory and marks *every* file under
   it as referenced. This is a deliberate over-approximation: glob-driven directories (a common
   Astro pattern for bulk-importing content) must never produce false-positive dead-file flags.

Output per file: `ReferenceSource { path, resolvedReferences: [String] }`. A separate step builds
inbound-reference counts per candidate file by inverting this map.

**Resolution safety rule:** a reference that can't be resolved (bare specifier like
`astro:content`, an unconfigured path alias) is simply not counted — it never causes a file to be
treated as "definitely referenced" *or* "definitely dead." This biases the whole system toward
under-flagging: the worst failure mode is "missed an actually-dead file," never "recommended
deleting something in use."

```swift
public enum DeadAssetScanner {
    public struct CleanupCandidate: Sendable, Equatable, Identifiable {
        public let id: String            // relative path
        public let path: String
        public let kind: Kind
        public let lastModified: Date
        public let referenceCount: Int

        public enum Kind: String, Sendable, Equatable {
            case component, layout, image
        }
    }

    /// Scans `projectRoot` and returns unused components/layouts/images. Pure over the
    /// filesystem snapshot at call time — no caching, no incremental state.
    public static func scan(projectRoot: URL) -> [CleanupCandidate]
}
```

### 3.2 `ProjectCleanupReport`

Thin combiner merging `DeadAssetScanner`'s candidates with `LinkGraph.orphanPages` (converted to a
`CleanupCandidate` with `kind: .page` and `referenceCount` = the existing inbound-link count) into
one sorted `[CleanupCandidate]` — directly matching the issue's requested table shape (File / Type
/ Last modified / Reference count).

```swift
public enum ProjectCleanupReport {
    public static func build(
        deadAssets: [DeadAssetScanner.CleanupCandidate],
        orphanPages: [SiteKnowledgeIndex.Document]
    ) -> [DeadAssetScanner.CleanupCandidate]
}
```

## 4. Trigger and data flow

On-demand only, matching the "images + pages + components/layouts" scope decision and the
project's general preference for cheap, explicit actions over continuous background cost (a full
reference scan is materially more expensive than dependency-sync's tiny JSON diff).

Flow when the user invokes "Scan for Cleanup Opportunities":

1. `SiteKnowledgeIndex.rebuild(siteID:projectRoot:)` — ensures the document index is fresh (may
   already be warm from other features; rebuilding is idempotent and cheap relative to the scan
   itself).
2. `DeadAssetScanner.scan(projectRoot:)` — walks `src/components/`, `src/layouts/`,
   `public/images/`, and the full source tree for reference extraction.
3. `LinkGraph.analyze(documents:)` — already-existing orphan-page computation, run over
   `SiteKnowledgeIndex.documents(siteID:)`.
4. `ProjectCleanupReport.build(...)` merges both into the report shown in the Cleanup section.

All of this is host-side Swift file I/O — no container, no MCP round-trip, consistent with
`ContentScanner`/`SiteKnowledgeIndex`'s existing architecture.

## 5. Delete action

Git-tracked delete, mirroring the existing `NativeContentOperations.processGitCommit` pattern
(`NativeContentOperations.swift:219`) exactly:

```
git rev-parse --git-dir              # confirm inside a repo
git rm -- <relPath>
git commit -m "Remove unused <kind>: <relPath>" -- <relPath>
```

New sibling function (e.g. `processGitDelete`), same `@Sendable` closure-injection shape as
`processGitCommit` for testability, using `ProcessSupervisor.shared.run` in production.

**This single mechanism covers both "Delete" and the issue's "Archive"/"automatic Git commit
before deletion" nice-to-haves.** Since the file is committed to git on removal, `git log`/
`git revert` *is* the archive/undo story — a separate archive mechanism would just duplicate what
git already provides. No new storage, no new UI for "restore from archive."

**Confirmation:** a lightweight alert before running the pipeline (destructive to the working
tree, even though git-recoverable). Copy is type-aware:

- Component/layout/image: "Delete this unused \<kind\>? This can be undone via git."
- Page: "Delete this orphaned page? Its content will be lost from the working tree. This can be
  undone via git."

**Failure handling:** if any step fails (dirty working tree, permission error, not a git repo), a
non-blocking error is surfaced and the file is left untouched on disk — never fall back to a
non-git raw delete, per the project's git-is-source-of-truth principle.

**Open editor/preview interaction:** if the file being deleted is the currently open editor tab or
active preview route, that tab/pane closes as part of the delete completing.

## 6. UI

A new "Cleanup" section appended at the bottom of the existing Navigator sidebar (after
Components/Styles), rendered directly by `SiteNavigatorView` from a new `ProjectCleanupModel`
(`@MainActor @Observable`, `AnglesiteApp`) — **not** threaded through
`NavigatorTree.buildNavigatorTree`, keeping that general-purpose tree builder decoupled from
cleanup-specific semantics (reference counts, delete, ignore).

- **Empty state** (no scan run yet this session): a single row, "Scan for Cleanup Opportunities."
- **After a scan:** one row per candidate — name plus a type/reference-count subtitle. Context
  menu offers **Open / Ignore / Delete**, mirroring the existing Rename context-menu pattern in
  `SiteNavigatorView`.
- **Open:** components/layouts/pages route through their existing `.file`/`.route` Navigator
  targets (same editor/preview behavior as everywhere else in the Navigator). Images have no
  in-app editor, so Open reveals the file in Finder (`NSWorkspace.shared.activateFileViewerSelecting`).
- **Ignore:** session-only, in-memory on `ProjectCleanupModel` — matching `RelatedPagesModel`'s
  existing "not persisted in v0" precedent (`RelatedPagesModel.ignored`). A fresh app launch
  re-surfaces a still-unreferenced file even if it was ignored in a prior session; smallest state
  footprint, consistent with the project's existing convention for this exact kind of dismissal.

## 7. Error handling

- Unreadable or oversized (`> 512_000` bytes, matching `SiteKnowledgeIndex`'s existing limit)
  files are skipped during reference extraction — contribute zero outbound references, never
  treated as proof of use or disuse.
- A file that fails to parse contributes zero outbound references — it can't incorrectly "prove"
  another file is used, and (per §3.1's safety rule) this can't cause a wrongful delete since delete
  is always a separate, confirmed, git-tracked user action.
- Delete failures produce a non-blocking alert; the candidate remains listed, unchanged on disk.

## 8. Rationale for out-of-scope items

- **Drafts/duplicates/empty collections** — fundamentally different heuristics (content age,
  textual similarity, collection emptiness) rather than reference-graph analysis. Bundling them
  into this slice would mean shipping two unrelated detection engines at once. Natural v2 using
  the same Cleanup section and candidate/action UI.
- **Fonts/icons/assets outside `public/images/**`** — nothing in the codebase models these as
  assets today (`SiteContentGraph`/`ContentScanner` only cover `public/images`). Adding a new asset
  category is separable follow-up work, not a natural extension of completing the existing stub.
- **Utility modules (`.ts`/`.js` under `src/utils/`)** — JS/TS import resolution has materially
  more edge cases (barrel files, re-exports, path aliases via `tsconfig.json`) than `.astro`
  component imports. Worth its own design pass once the `.astro` case is proven out.
- **Continuous scanning** — a full reference scan is not cheap enough to run on every file-watch
  event the way `SiteContentGraph`'s lightweight bulk-load is; on-demand keeps v1's cost bounded
  and predictable.
- **Separate Archive action** — redundant with git-tracked delete (§5); would add a second
  recovery mechanism with no benefit over `git log`/`git revert`.

## 9. Testing

All new logic is pure Swift over in-memory or fixture data — no container, no network, no live
git server:

- `DeadAssetScannerTests` — reference-extraction unit tests: import resolution, relative-path
  resolution against the referencing file's directory, glob-directory blanket marking, frontmatter
  `layout:` counting, and the unresolvable-specifier safety rule (`LinkGraphTests`-style inline
  fixtures, no disk I/O).
- A disk-fixture suite (`ContentScannerTests`-style temp directory) covering the full
  `scan → report` path against a small synthetic Astro project tree, including at least one
  component that's dead, one that's imported, one glob-covered directory, and one image referenced
  only via its public path.
- `ProjectCleanupReportTests` — merge logic combining `DeadAssetScanner` candidates with
  `LinkGraph.orphanPages`.
- Git-delete pipeline unit tests against a real temp git repo (same style as existing
  `RepoBootstrap`/`NativeContentOperations` git tests): success, dirty-tree failure, and
  non-repo failure.
- No container/MCP involved anywhere in this feature, so no e2e/`XCSkip`-gated tests are needed.

## 10. Files touched (indicative — implementation plan will pin exact paths)

- New: `Sources/AnglesiteCore/DeadAssetScanner.swift` — reference extraction + candidate detection
- New: `Sources/AnglesiteCore/ProjectCleanupReport.swift` — merge with `LinkGraph.orphanPages`
- Modify: `Sources/AnglesiteCore/NativeContentOperations.swift` — add `processGitDelete` sibling to
  `processGitCommit`
- New: `Sources/AnglesiteApp/ProjectCleanupModel.swift` — `@Observable` model driving the Cleanup
  section (scan trigger, ignore set, delete confirmation/execution)
- Modify: `Sources/AnglesiteApp/SiteNavigatorView.swift` — render the new Cleanup section + context
  menu actions
- New/modify: test targets per §9
