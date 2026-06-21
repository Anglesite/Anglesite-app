# RelevantEntities — surface most-recent sites to Siri/Spotlight suggestions

**Issue:** #124 (the `RelevantEntities` evaluation item)
**Date:** 2026-06-20
**Status:** Design approved

## Context

Issue #124 is the Phase B.1 findings/gap-analysis umbrella. Most of its items
have shipped via sub-issues (LongRunningIntent #125, CancellableIntent #126,
Spotlight `IndexedEntity` index #144, View Annotations #133/#145–150). Three
items remain under #124 itself; only one is cleanly actionable today:

- **`RelevantEntities` evaluation** — this spec. *(actionable now)*
- `SyncableEntity` / `SyncableEntityIdentifier` — gated on the iOS thin client
  #71 (itself container-blocked). *(blocked)*
- Re-scan each WWDC for a publishing/dev-tooling schema. *(research only)*

`RelevantEntities` is **not implemented anywhere** in `Sources/` today (verified
by grep). This adds it.

### What "relevant entities" buys us (vs. the existing Spotlight index)

`SpotlightIndexer` (`Sources/AnglesiteIntents/SpotlightIndexer.swift`) already
maintains the Spotlight **searchable semantic index** for `SiteEntity` — that's
what lets Siri *resolve* "my portfolio site" by name. `RelevantEntities` is a
distinct macOS 27 surface: it tells the system which entities are **most
relevant right now**, so Siri/Spotlight can proactively *suggest* them
(suggestions, predictions) without the user naming one. The natural relevance
signal for Anglesite is **recency** — the most-recently-used sites.

## Decisions

1. **Relevance signal: top-N most-recently-used sites.** `SiteStore.sites` is
   already MRU-sorted (`recents.json`; `touch(id:)` bumps `lastSeen`), so the
   signal is `sites.prefix(N)`. Keeps everything in `AnglesiteCore` /
   `AnglesiteIntents`, fully testable, no app-window coupling. Default **N = 3**.
   (Rejected: single frontmost-window site — couples to app-target window state
   the MAS/CI test path can't exercise; and active+recent hybrid — more wiring
   for marginal v0 value.)

2. **Reorder freshness via the existing `changeStream()`.** Opening a site bumps
   MRU through `touch(id:)`, which deliberately **skips** the data-only
   `changeHandler` (`SiteStore.swift:176` — "a reorder changes no entity data")
   that drives Spotlight. But `touch()` *does* yield to
   `SiteStore.changeStream()` (`SiteStore.swift:178`), the AsyncStream built for
   "UI observers (Open Recent / launcher)." That stream yields the full
   MRU-sorted snapshot on subscribe, on every data change, **and on every
   reorder** — exactly the order-aware signal `RelevantEntities` needs.

   Therefore: **subscribe to `changeStream()`; add no new `SiteStore` surface.**
   This realizes the intent of a "dedicated order-changed handler" (reorder
   freshness without polluting the data-only `changeHandler`) using a channel
   that already exists.

## Architecture

New, isolated to `Sources/AnglesiteIntents/`, mirroring `SpotlightIndexer.swift`.

### `RelevantEntitiesUpdater.swift`

```swift
/// Test seam over the system RelevantEntities surface, mirroring SpotlightIndexBackend.
public protocol RelevantEntitiesBackend: Sendable {
    func update(_ entities: [SiteEntity]) async throws
}

/// Pushes the top-N most-recently-used sites to the system "relevant entities"
/// suggestion surface. Single entry point: `refresh(_:)`. Diff-based: skips the
/// backend call when the published top-N id list is unchanged (same posture as
/// SpotlightIndexer.lastIndexedIDs).
public actor RelevantEntitiesUpdater {
    public static let shared = RelevantEntitiesUpdater(backend: LiveRelevantEntitiesBackend())

    public struct Outcome: Sendable, Equatable {
        public let published: Int
        public let skipped: Bool   // true when top-N id list was unchanged
    }

    private let backend: any RelevantEntitiesBackend
    private let maxCount: Int
    private var lastPushedIDs: [String]   // ORDER-significant: [a,b,c] != [b,a,c]

    public init(backend: any RelevantEntitiesBackend, maxCount: Int = 3) { ... }

    @discardableResult
    public func refresh(_ sites: [SiteStore.Site]) async throws -> Outcome {
        let top = Array(sites.prefix(maxCount))
        let ids = top.map(\.id)
        guard ids != lastPushedIDs else { return Outcome(published: top.count, skipped: true) }
        try await backend.update(top.map(SiteEntity.init))
        lastPushedIDs = ids                 // advance only on success → retry on throw
        return Outcome(published: top.count, skipped: false)
    }
}

/// Production backend. The ONLY place the real SDK API is called.
struct LiveRelevantEntitiesBackend: RelevantEntitiesBackend {
    func update(_ entities: [SiteEntity]) async throws {
        // RelevantEntities.shared.updateEntities(entities, for: <context>)
        // Exact signature confirmed against the Xcode 27 SDK at implementation time.
    }
}
```

Notes:
- `lastPushedIDs` compares **ordered** id lists so a pure reorder of the lead
  sites (a→b) re-publishes, while a no-op reorder further down the list (that
  doesn't change the top-N) is skipped.
- Dedup posture matches `SpotlightIndexer`: `lastPushedIDs` advances only on a
  successful backend call, so a thrown error replays on the next snapshot.

### Wiring — `Bootstrap.swift`

After the existing `SiteStore.setChangeHandler` / content-graph setup, spawn one
app-lifetime consumer of the change stream:

```swift
let relevant = RelevantEntitiesUpdater.shared
Task {
    for await sites in SiteStore.shared.changeStream() {
        do { try await relevant.refresh(sites) }
        catch { relevantLog.error("relevant refresh failed: \(error.localizedDescription, privacy: .public)") }
    }
}
```

- No change to `SiteStore`.
- No change to the existing Spotlight `changeHandler` (stays data-only).
- The task lives for the app's lifetime; harmless on the CI/headless path
  (stream simply emits the loaded snapshot once).
- `changeStream()` yields the current snapshot on subscribe, so the initial
  relevant set is published without a separate kick.

## Data flow

```
SiteStore mutation (record / remove / load / touch)
        │
        ├── changeHandler(sites)  ──► SpotlightIndexer.reindex   (searchable index; data changes only)
        │
        └── changeStream() yield  ──► RelevantEntitiesUpdater.refresh(top-N)  (suggestions; data + reorder)
                                            │
                                            └─ LiveRelevantEntitiesBackend ─► system RelevantEntities surface
```

## Error handling

- Backend throw is logged (OSLog, `dev.anglesite.app` / category
  `relevant-entities`) and swallowed in the bootstrap loop; `lastPushedIDs`
  stays put so the next snapshot retries. A failed suggestion push must never
  take down the app or the stream consumer.
- Empty `sites` → `top` is empty; we still push an empty set (clears stale
  suggestions) unless the last push was already empty (dedup).

## Testing

`Tests/AnglesiteIntentsTests/RelevantEntitiesUpdaterTests.swift`, mirroring
`SpotlightIndexerTests` (recording fake backend actor). Fully CI-runnable — no
system daemon, no app window.

- first refresh publishes top-N (N=3) in MRU order, drops the 4th+
- refresh with an unchanged top-N id list skips the backend call (`skipped == true`)
- a reorder that changes the lead site re-publishes
- a reorder *below* the top-N (top-N unchanged) is skipped
- empty snapshot clears (publishes empty once, then dedups)
- backend throw leaves `lastPushedIDs` unchanged → next refresh retries

## Integration risks (verify at implementation, do not assume)

1. **Exact API.** #124 lists `RelevantEntities.shared.updateEntities(_:for:)` as
   "verified," but confirm the real signature (especially the `for:` argument)
   against the Xcode 27 SDK. If it differs, only `LiveRelevantEntitiesBackend`
   changes — the seam contains the blast radius.
2. **CI build portability.** If the `RelevantEntities` call doesn't compile on
   CI's older toolchain, gate `LiveRelevantEntitiesBackend`'s body behind
   `#if compiler(>=6.4)` with a no-op `#else`, mirroring the
   `FoundationModelEditInterpreter` / `UnavailableEditInterpreter` pattern
   already in `Bootstrap.swift`. The protocol, actor, and tests stay
   toolchain-agnostic.

## Out of scope

- `SyncableEntity` / `SyncableEntityIdentifier` (#71-gated).
- WWDC publishing/dev-tooling schema re-scan.
- Active/frontmost-window relevance (rejected above).

This change completes the `RelevantEntities` item only; #124 stays open for the
two items above.
