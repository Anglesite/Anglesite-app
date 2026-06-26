# Incremental Knowledge Reindex — Design

**Date:** 2026-06-26
**Issue:** [#307](https://github.com/Anglesite/Anglesite-app/issues/307) (gap #1 — incremental reindex)
**Status:** Approved, ready for implementation plan

## Problem

The `SiteKnowledgeIndex` (shipped in #332) is the project-local retrieval index that
augments assistant prompts with relevant Astro-site context. Today it is built **once**, on
site open (`rebuild(siteID:projectRoot:)`), and unloaded on close. Any edit made after a site
opens — whether by the app's own MCP edit pipeline, VS Code, a `git pull`, or the dev server —
leaves the index **stale until the site is reopened**.

The index already exposes the seams for incremental updates — `upsertFile(siteID:projectRoot:relativePath:)`
and `removeFile(siteID:relativePath:)` — but nothing calls them. This design wires a filesystem
watcher to those seams so retrieval stays fresh while a site is open.

## Constraints & context

- **#72 — git is the source of truth.** The app must never be the only way to edit a site. So an
  edit-pipeline hook alone is insufficient: external edits (VS Code, git, the dev server) must
  also refresh the index. Only a filesystem watcher catches all of them. (Decision: FS watcher,
  not an edit-pipeline hook.)
- **Both runtimes index the host `Source/` directory.** `LocalSiteRuntime` runs `astro dev` with
  cwd = the package's `Source/`. `LocalContainerSiteRuntime` (#69) clones the **host** `Source/`
  repo into the guest as a `file://` remote and rebuilds the knowledge index from that same host
  path — *not* the guest filesystem. So a single host-side watcher on `Source/` covers both
  runtimes. (In the container case the host `Source/` only changes on git push-back, but watching
  it is still correct and harmless.)
- **MAS sandbox.** Each `SiteWindow` already holds a security-scoped bookmark grant covering the
  package while a site is open; the runtime reads files under `Source/` throughout its lifetime.
  FSEvents requires no additional entitlement and operates within that grant.

## Approach

A dedicated `SiteFileWatcher` in `AnglesiteCore`, owned by each `SiteRuntime`, wrapping an
`FSEventStream` on the package's `Source/` directory. It forwards debounced batches of changed
paths; the runtime translates each change into a call on the existing `SiteKnowledgeIndex` seam.
The index itself is unchanged.

Rejected alternatives:

- **Fold watching into `SiteKnowledgeIndex`** — couples filesystem I/O and stream lifecycle into
  the index actor and makes it hard to test without real files.
- **kqueue / `DispatchSource` per file** — needs one file descriptor per watched file; does not
  scale to a whole project tree.
- **Edit-pipeline hook only** — misses every external edit; at odds with #72.

## Components

### `SiteFileWatching` protocol (the seam)

```swift
public protocol SiteFileWatching: Sendable {
    /// Begin watching `root`, delivering debounced batches of changes to `onBatch`.
    func start(root: URL, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws
    func stop()
}

public struct FileChangeBatch: Sendable, Equatable {
    /// Absolute URLs of paths FSEvents reported as changed in this batch.
    public let paths: [URL]
    /// FSEvents signalled it dropped per-file granularity (coalesced bulk event, root moved,
    /// mount/unmount). The consumer should fall back to a full rebuild.
    public let needsFullRescan: Bool
}
```

Tests inject a `MockFileWatcher` conforming to this protocol and deliver synthetic batches.

### `FSEventsFileWatcher: SiteFileWatching` (real impl)

- Creates an `FSEventStream` with flags `kFSEventStreamCreateFlagFileEvents |
  kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes`.
- Latency `0.3s` — FSEvents' own coalescing **is** the debounce; no separate timer.
- Runs on a dedicated serial dispatch queue; schedules/invalidates the stream on `start`/`stop`.
- Maps each callback into a `FileChangeBatch`. `needsFullRescan` is set when any event flag
  includes `MustScanSubDirs`, `RootChanged`, `Mount`, or `Unmount`.

### Runtime wiring (consumer)

Both `LocalSiteRuntime` and `LocalContainerSiteRuntime` gain:

- An injected `makeFileWatcher: @Sendable (URL) -> any SiteFileWatching`, defaulting to the
  FSEvents impl, so existing callers and tests are unaffected.
- An `applyFileChanges(_ batch:generation:)` method (see Data flow).
- Watcher start after the knowledge index `rebuild` succeeds and the loaded-site marker is set;
  watcher stop alongside the existing `unload` in teardown.

The headless MCP path (`startHeadlessMCP`) populates no index, so it starts no watcher.

## Data flow

```
FSEvents on Source/ → debounced FileChangeBatch → runtime.applyFileChanges(batch, gen)
    guard gen == generation                          // drop if the site switched mid-batch
    if batch.needsFullRescan:
        await knowledgeIndex.rebuild(siteID:, projectRoot: Source/)
    else for each path in batch.paths:
        relative = path relative to Source/
        if relative is under a skipped dir (node_modules/.git/dist): ignore
        else if file exists at path:
            await knowledgeIndex.upsertFile(siteID:, projectRoot:, relativePath: relative)
        else:
            knowledgeIndex.removeFile(siteID:, relativePath: relative)
```

Notes:

- `upsertFile` already calls `shouldIndex` + size/encoding checks internally and **removes** the
  entry when the file is non-indexable, oversized, or binary — so the runtime stays a thin
  exists-check and never needs to replicate the index's filtering.
- Skipped directories are filtered **before** the index call to avoid an `npm install` event
  flood. The skip set is lifted out of `SiteKnowledgeIndex` into a small shared predicate so the
  watcher consumer and the index's `walk` agree on what to ignore.
- The `generation` guard mirrors the existing `start()`/`stop()` pattern: a batch that arrives
  after the site has been switched or stopped is dropped.

## Error handling

- **FSEvents start failure** is logged via `LogCenter` and leaves the runtime `.ready`. Retrieval
  simply falls back to open-time-only freshness — non-fatal, mirroring the best-effort MCP spawn.
- **Stale batches** (site switched/stopped) are dropped by the generation guard.
- **Bulk/coalesced events** degrade to a full `rebuild` via `needsFullRescan` rather than risking
  a partially-updated index.

## Testing

- **Unit (deterministic, no real FS):** inject `MockFileWatcher`; deliver synthetic batches for
  created / modified / deleted files; assert `knowledgeIndex.documents(siteID:)` reflects each
  upsert and remove.
- **Unit:** a `needsFullRescan` batch triggers a full `rebuild` — verified by placing a file on
  disk that is absent from the per-file event list and asserting it appears after the batch.
- **Unit:** paths under `node_modules` / `.git` / `dist` in a batch are ignored (no index change).
- **Integration (tolerant):** one real-`FSEventsFileWatcher` test over a temp directory using a
  poll-until-timeout helper, to prove the FSEvents path actually fires. Kept minimal to avoid CI
  timing flake; correctness rests on the mock-driven tests.

## Non-goals (v1)

- **`SiteContentGraph` freshness.** The pages/posts/images graph that feeds Spotlight/Siri still
  rebuilds only on open — it has no per-file upsert API today. It is the natural **next** consumer
  of this same watcher and is deliberately out of scope here.
- **Semantic / embedding retrieval.** Unrelated; tracked separately under #307.

## Files

| File | Change |
|---|---|
| `Sources/AnglesiteCore/SiteFileWatcher.swift` | **new** — `SiteFileWatching`, `FileChangeBatch`, `FSEventsFileWatcher`, shared skip-dir predicate |
| `Sources/AnglesiteCore/LocalSiteRuntime.swift` | own/start/stop watcher; add `applyFileChanges` |
| `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift` | identical wiring |
| `Sources/AnglesiteCore/SiteKnowledgeIndex.swift` | extract skip-dir set into the shared predicate |
| `Tests/AnglesiteCoreTests/SiteFileWatcherTests.swift` | **new** — mock-driven + tolerant real-FS tests |
| `Tests/AnglesiteCoreTests/IncrementalReindexTests.swift` | **new** — runtime applies batches to the index |
