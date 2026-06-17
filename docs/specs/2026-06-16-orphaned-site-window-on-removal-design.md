# Auto-close an open SiteWindow when its site is removed (#188)

**Date:** 2026-06-16
**Issue:** [#188 — Open SiteWindow not signalled when its site is removed from the registry](https://github.com/Anglesite/Anglesite-app/issues/188)
**Surfaced in:** review of #187 (the "Remove Site" launcher action, #186)

## Problem

When an owner removes a site via the launcher (`SitesLauncherView.removeSite` → `SiteStore.remove(id:)`),
the store's change handler fires. That handler is **single-subscriber by design** — today the only
consumer is `SpotlightIndexer`, wired in `AnglesiteIntents.bootstrap`. An open `SiteWindow` for the
removed site does **not** observe registry changes, so:

- The window stays open showing a now-orphaned site.
- It keeps running that site's dev-server / MCP subprocess for a registry entry that no longer exists.

`SitesLauncherView.removeSite` already carries an inline comment documenting this exact gap.

## Decision

When a site is removed while its window is open, **the window auto-closes**. Rationale:

- Removal is already behind an explicit confirmation dialog in the launcher, so the user just chose
  this — the window vanishing is the intuitive consequence ("I removed this site; of course its
  window closed").
- `SiteWindow.onDisappear` already performs full teardown: `preview.close()` stops the
  dev-server/MCP subprocess, the annotation provider is unregistered, and (MAS) the security-scoped
  grant is released. Dismissing the window therefore *is* the teardown — the
  "no orphaned subprocess" acceptance criterion is satisfied by construction.
- Chat history is ephemeral per-window (created in `loadAndStart`, dropped in `onDisappear`), so
  nothing durable is lost. Site content lives on disk (filesystem is the source of truth) and is
  untouched by removal.

Alternatives considered and rejected:

- **Stop subprocess + show a "removed" banner with a Close button.** Gentler, but more UI for no
  real benefit given removal was just explicitly confirmed.
- **Block removal while a window is open.** Worse UX (user must hunt for and close the window first)
  and awkward to implement — SwiftUI doesn't cleanly enumerate open `WindowGroup` windows by value.

## Architecture

Approach: **AsyncStream broadcast** added to `SiteStore`, consumed per-window. Chosen over a full
multicast rewrite of the existing `changeHandler` because subscription lifecycle becomes free
(task cancellation prunes the subscriber) and the working Spotlight wiring is left untouched.

### Components

1. **`SiteStore` (actor) — add a UI-observer broadcast.**
   - New state: `private var changeStreamContinuations: [UUID: AsyncStream<[Site]>.Continuation] = [:]`.
   - New API: `public func changeStream() -> AsyncStream<[Site]>`. Each call registers a fresh
     continuation under a new `UUID`; the stream's `onTermination` removes that continuation from
     the dictionary (hopping back onto the actor to mutate it). On subscribe it yields the current
     `sites` snapshot once, so a subscriber isn't blind until the next mutation and a remove that
     races subscription is caught immediately (see Edge cases).
   - `emitChange()` gains a second step: after the existing `await handler(sites)`, iterate
     `changeStreamContinuations.values` and `yield(sites)` to each. `yield` is non-blocking and does
     not await consumers, so this cannot stall a store mutation.
   - The existing `changeHandler` / `setChangeHandler` / `ChangeHandler` typealias are **unchanged**;
     the Spotlight indexer keeps its awaited-as-part-of-mutation semantics.

2. **`SiteWindow` (view) — observe and auto-close.**
   - New `.task(id: siteID) { await observeRemoval() }` modifier alongside the existing
     `.task(id: siteID) { await loadAndStart() }`.
   - `observeRemoval()`: returns immediately if `siteID == nil`. Otherwise iterates
     `SiteStore.shared.changeStream()`; on the first snapshot that does **not** contain a site whose
     `id == siteID`, calls `dismissWindow()` and returns. The `for await` loop is implicitly
     cancelled when the window tears down or `siteID` changes, terminating the stream.
   - No new teardown code: `dismissWindow()` triggers `onDisappear`, which already does the full
     stop. `dismissWindow()` (no-arg) is the same call `loadAndStart` already uses to route an
     unresolvable window back to the launcher, so the pattern is established in this file.

### Data flow

```
SitesLauncherView.removeSite
  └─ SiteStore.remove(id:)
       ├─ sites.removeAll { $0.id == id }
       ├─ persist()
       └─ emitChange()
            ├─ await changeHandler(sites)            // unchanged: SpotlightIndexer reindex
            └─ for c in changeStreamContinuations: c.yield(sites)   // NEW: UI broadcast
                 └─ removed site's SiteWindow.observeRemoval sees its id absent
                      └─ dismissWindow()
                           └─ onDisappear → preview.close() (stops dev-server/MCP) + grant release
       (other windows receive a snapshot that still contains their id → no-op)
```

## Edge cases

- **nil `siteID`** (SwiftUI restored an empty window): `observeRemoval` returns without subscribing;
  `loadAndStart` already routes such windows to the launcher.
- **Subscribe-time snapshot.** `changeStream()` yields the current `sites` once on subscribe. This
  guards a race where the site is removed in the window between `loadAndStart` resolving it and
  `observeRemoval` subscribing: the first delivered snapshot already lacks the id, so the window
  closes promptly instead of waiting for a future mutation. A window whose site is still present on
  subscribe gets a redundant first snapshot containing its id — a harmless no-op.
- **`refresh()` prunes a stale entry.** A window whose site disappears via `refresh()` (not an
  explicit `remove`) auto-closes through the same membership check — desirable, since the entry is
  genuinely gone from the registry.
- **Re-entrancy / double-dismiss.** The membership check is idempotent and `observeRemoval` returns
  after the first dismiss; the `.task` is then cancelled, so no second `dismissWindow()` fires.
- **Continuation leak / yield-after-finish.** `onTermination` prunes the continuation on stream
  termination; yielding to a finished `AsyncStream` continuation is a documented no-op, so an
  in-flight `emitChange` racing a termination cannot trap.

## Testing

**`SiteStoreTests` (Swift Testing, `AnglesiteCoreTests`) — store mechanics:**

1. Two concurrent `changeStream()` subscribers each receive a snapshot on `add`, `remove`, and
   `refresh`.
2. After `remove(id:)`, the delivered snapshot does **not** contain the removed id; a sibling site
   still present is still contained.
3. A new subscriber receives the current snapshot immediately on subscribe (subscribe-time yield).
4. Terminating a stream (drop the iterator / break the loop) prunes its continuation: a subsequent
   `emitChange` does not trap and surviving subscribers still receive the snapshot.

**Manual smoke (recorded here; not unit-testable through SwiftUI):**

- Open a site window, then remove that site from the launcher → window auto-closes; confirm via the
  debug pane that the site's dev-server/MCP subprocess stops (no orphaned child), and on MAS that
  the security-scoped grant is released.
- With two site windows open, remove one → only its window closes; the other keeps running.

The window's auto-close decision is deliberately a one-line membership check
(`!snapshot.contains { $0.id == siteID }`) so the untested SwiftUI glue is trivial and the tested
store mechanics carry the weight.

## Out of scope

- The launcher-side removal action itself (shipped in #187).
- Multicasting the indexer's `changeHandler` or migrating it onto the new stream — the indexer's
  awaited semantics are intentionally preserved.
- Any "site removed" banner / undo affordance — auto-close is the decided UX.

## Acceptance (from #188)

- [x] Removing a site with an open window leaves no orphaned dev-server/MCP subprocess running
      (satisfied by `dismissWindow()` → `onDisappear` → `preview.close()`).
- [x] Defined, tested UX for the open-window case (auto-close; store mechanics unit-tested, window
      glue covered by manual smoke).
