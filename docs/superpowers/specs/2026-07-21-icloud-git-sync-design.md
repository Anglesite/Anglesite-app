# Git repos in iCloud: split repo + single-file sync artifact

**Issue:** #863 — "Investigation: git repos in iCloud"
**Date:** 2026-07-21
**Status:** Design approved; supersedes the unshipped app-wiring half of
[`2026-06-21-icloud-bundle-sync-design.md`](../../specs/2026-06-21-icloud-bundle-sync-design.md) (#283)
and replaces its `BundleSync` actor.

## Problem

A `.anglesite` package kept in iCloud Drive drags its live `Source/.git` directory into sync. Git
cannot tolerate that: a repo is thousands of small files synced independently and out of order;
concurrent edits on two Macs produce iCloud conflict copies of `HEAD`/`index` that silently corrupt
the repo; "Optimize Mac Storage" evicts objects out from under git. Nothing in the app today excludes
`.git` from iCloud or reconciles multi-Mac edits.

**Requirements settled during investigation:**

- **True concurrent editing** — two Macs editing the same site at once must reconcile, not just
  sequential handoff.
- **iCloud-only baseline** — no hosted git server, no accounts. A hosted remote may become an
  optional upgrade later; it is not the design's arbiter.
- **MAS App Sandbox** — `/usr/bin/git` cannot execute at all under the sandbox (#640); the only git
  substrates are in-process SwiftGit2/libgit2 (#653) and the container runtime.
- **Git stays the source of truth (#72)** — `Source/` must remain a real repo that `cd`, `git`,
  VS Code, and `git clone` can use outside the app.

## Investigation record: the option space

The four directions from #863, plus the prior-art bundle approach, re-evaluated from scratch:

| Option | Verdict | Why |
|---|---|---|
| Live `.git` in iCloud (status quo) | Rejected | Multi-file sync is interleaved and unordered; conflict copies of `HEAD`/`index` corrupt silently; eviction dataless-faults objects. This is the bug. |
| Mounted binary container (sparsebundle/DMG holding the repo) | Rejected | Concurrent mounts corrupt at the filesystem level — worse than git corruption and invisible to git. No supported path for a sandboxed MAS app to attach disk images. |
| Tmp checkout, push to a bare repo inside `.anglesite` | Rejected (reduces) | A bare repo is still thousands of files in iCloud — identical corruption under concurrent push. Making the push target a single file turns this into the artifact approach below. |
| Git worktrees / `--separate-git-dir` | Half-solution | Keeps the live `.git` out of iCloud but provides no transport between Macs. Adopted as the *local* half of the chosen design. |
| Hosted git server (required) | Rejected as baseline | Only option with atomic ref updates, but conflicts with the local-first, no-account product ethos. Kept as a future optional remote. |
| **Single-file repo artifact through iCloud** | **Chosen** | One opaque file syncs atomically. Concurrent writes yield NSFileVersion conflict versions — each a complete, valid history — which git's own merge machinery can reconcile. Corruption becomes an ordinary merge. |

**Prior-art finding.** The #283 `BundleSync` actor (AnglesiteCore) is unshippable dead code in the
MAS app: its default runner shells out to `git` (impossible under the sandbox per #640), and the
`InProcessGit` shim implements none of the commands it needs (`bundle`, `fetch`, `merge`, `init`).
libgit2 upstream has no bundle support either. This design replaces `BundleSync` outright.

**External facts relied on:**

- iCloud Drive does not upload any file or folder named `*.nosync` (long-stable, semi-official;
  Finder badges it). There is no official per-item exclusion API.
- A `.git` **gitfile** may contain a *relative* `gitdir:` pointer (the submodule mechanism), which
  libgit2 both follows (`git_repository_open_ext`) and creates
  (`git_repository_init_ext` with `workdir_path`).
- Bundle v2 is a text header of refs plus a packfile — writable via `git_packbuilder`, readable via
  header parse + `git_indexer`, and clonable by stock git.

## Design

### 1. Package layout: split repo

```
Foo.anglesite/
├── Info.plist                  # unchanged (UUID identity)
├── Source/                     # working tree — syncs as plain files
│   ├── .git                    # gitfile: "gitdir: ../Config/repo.nosync" (relative)
│   └── … site files …
└── Config/
    ├── repo.nosync/            # the REAL git dir — iCloud never uploads *.nosync
    └── sync/
        └── source.bundle       # single-file synced artifact (existing path, kept)
```

- `Config/repo.nosync/` is the live repository: per-Mac, never synced, rebuildable at any time from
  the bundle (which doubles as the corruption-recovery point, including if `.nosync` ever regresses).
- The relative gitfile keeps the package movable as a unit; `cd Source && git status`, VS Code, and
  `git clone Foo.anglesite/Source` keep working on the Mac that owns the live repo. AirDrop/USB
  copies carry the repo intact (`.nosync` affects only iCloud upload).
- On a peer Mac the gitfile arrives dangling (target never synced). That is a defined state — the
  app rehydrates (§4), never errors.
- The layout applies uniformly, including packages outside iCloud, so there is exactly one package
  shape. `AnglesitePackage` gains `liveRepositoryURL`; `syncBundleURL` already exists.

### 2. SyncEngine and the artifact

A new `SyncEngine` actor (AnglesiteCore) supersedes and deletes `BundleSync`. It talks
SwiftGit2/libgit2 directly; the `InProcessGit` string-args shim is untouched for existing callers.

- **`push()`** — no-op when the artifact's heads already match the repo (no idle iCloud churn);
  otherwise write a sibling temp, verify, swap under `NSFileCoordinator`.
- **`pull()`** — materialize the bundle if evicted (`startDownloadingUbiquitousItem`; visible
  "waiting for iCloud" state on timeout), fetch it and every NSFileVersion conflict version of it
  into per-source remote namespaces, then reconcile (§3).
- **`SyncArtifact` seam.** Primary codec: bundle v2 on libgit2 (interop bonus: stock
  `git clone source.bundle` works). Named fallback if bundle v2 proves gnarly: a compressed archive
  of a bare repo, fetched via libgit2 local transport from an unpacked temp. Swappable behind the
  seam without touching `SyncEngine`.

**App wiring** (the piece #283 never received): `pull()` on site open and when an
`NSMetadataQuery`/file-presenter observes the bundle change while a window is open; debounced
`push()` after each successful `BackupCommand` auto-commit, after deploy, and on app background.

### 3. Concurrency: merge over conflict versions

When two Macs write `source.bundle` simultaneously, iCloud keeps one as current and the rest as
NSFileVersion conflict versions — each a complete bundle. Reconciliation on every `pull()`:

1. **Snapshot** — auto-commit local working-tree changes (existing `BackupCommand` path) so the
   repo is clean before history moves.
2. **Fetch all versions** — current bundle → `refs/remotes/icloud/<branch>`; each conflict version
   → `refs/remotes/peer-N/<branch>`.
3. **Reconcile** — fast-forward when behind; on divergence, libgit2 three-way merge. Clean merges
   auto-commit (message records both tips). Only textual conflicts stop the line and surface in UI —
   never auto-resolved, never rewound (the #283 safety contract, upgraded from "refuse" to "merge").
4. **Converge** — after all versions merge: resolve the NSFileVersions, force-checkout merged HEAD
   into `Source/`, `push()` the merged bundle. Both Macs run the same procedure; the system
   converges without an arbiter.

**Conflict UX.** A conflicted site shows a non-blocking banner ("This site was edited on two Macs —
2 files need attention") with a per-file resolution sheet: keep this Mac's / keep the other's / open
both. Resolution completes the merge commit. Until resolved the site stays editable locally; pushing
of that branch pauses (incoming bundles still fetch — nothing is lost).

**Working-tree conflict copies.** `Source/` files also sync as plain files, so iCloud can drop
`index 2.astro`-style copies there. Both sides' content already lives in git history (step 1 ran on
both Macs), so these are redundant: files matching iCloud's conflict-copy naming are swept into
`Config/conflicts/` — quarantined and surfaced in the same sheet, never silently deleted.

### 4. Migration, peer bootstrap, import/export

- **In-place migration** (`RepoRelocator`, idempotent, file-coordinated): opening a package whose
  `Source/.git` is a directory moves it to `Config/repo.nosync/` and writes the gitfile. Every open
  heals toward the canonical layout.
- **Peer bootstrap** (dangling gitfile + synced `Source/` + bundle): init the live repo, fetch the
  bundle, point the branch at its head, then diff the synced working tree against that head — file
  edits newer than the bundle are committed on top as a snapshot, not clobbered.
- **File ▸ Import** relocates an embedded `.git` like migration. **File ▸ Export** re-embeds:
  the exported copy gets `repo.nosync` copied back to `Source/.git` as a directory, so exports are
  plain self-contained repos with no Anglesite-isms.
- **Integrity check on open:** if the live repo fails to open, rebuild it from the bundle via the
  peer-bootstrap path.

### 5. Testing

- **Unit (CI-safe, no iCloud):** `SyncEngine` against local fixtures — artifact round-trip, no-op
  push, fast-forward, clean merge, conflicted merge, fresh peer, dangling-gitfile repair, migration,
  export re-embed. NSFileVersion sits behind a small `VersionStore` seam faked in tests (real
  conflict versions cannot be manufactured in CI). libgit2-touching suites use
  `@Suite(.serialized)`.
- **Interop gate:** a bundle we write must `git clone` cleanly with system git —
  `.enabled(if:)` on git availability; runs in CI.
- **Manual QA doc:** two-Mac checklist (sequential handoff, simultaneous edit, offline edit,
  eviction), since CI cannot exercise real iCloud.

## Non-goals

- Hosted-remote upgrade (future work; slots in as an ordinary additional remote).
- iOS / remote-runtime sync.
- Merging `Config/` itself — per-site app state stays last-writer-wins.

## Risks

- **`.nosync` is semi-official.** Mitigated: the bundle is always a complete recovery point, and the
  integrity check rebuilds a mangled live repo automatically.
- **Bundle v2 on libgit2 is bespoke.** Mitigated: the `SyncArtifact` seam names the bare-repo-archive
  fallback, and the CI interop gate proves the codec against real git on every run.
- **Uncommitted simultaneous edits.** Frequent auto-commits keep the uncommitted window small; the
  quarantine sweep guarantees no silent data loss inside it.
