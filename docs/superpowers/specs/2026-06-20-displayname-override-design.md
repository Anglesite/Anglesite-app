# Wire `SiteSettings.displayName` override into the displayed site name (#266)

**Date:** 2026-06-20
**Issue:** #266 (follow-up from #242 P4 / PR #264)
**Branch:** `fix/266-displayname-override`

## Problem

#242 P4 established `SiteConfigStore` (`Config/settings.plist`) with a
`SiteSettings.displayName` field — "owner-facing display name override; nil falls
back to the package marker's displayName." The store is in place and tested, but
nothing consumes the override: the app shows the marker's `displayName`
everywhere (launcher list, window title, drawers, `SiteEntity`/Siri). This makes
`SiteConfigStore` forward infrastructure with no live consumer.

This change makes the override live **and** adds a rename UI, closing #266.

## Approach: bake the resolved name at `Site.make()`

Every UI consumer reads `SiteStore.Site.name`, and `recents.json` persists it. So
resolving the override **once**, where `Site` is constructed from disk,
propagates it everywhere with a single change — consistent with how `isValid`
and `lastSeen` are already cached at `make()` time.

`Site.make()` will resolve:

```
name = settings.displayName?.trimmed.nonEmpty ?? marker.displayName
```

**Alternative considered — live resolution at each display site:** rejected. It
would force async `SiteConfigStore` loads into every view and contradicts the
existing "cache resolved fields in recents.json" model. The only staleness is a
hand-edit of `settings.plist` while the app is closed — the same property the
marker name already has; the next `record()` re-resolves it.

## Components

### 1. `SiteConfigStore` — sync read seam (Core)

`SiteConfigStore.load()` is async (actor), but `Site.make()` is synchronous.
Extract the decode logic into a `nonisolated static` helper and have `load()`
delegate to it:

```swift
nonisolated static func read(from configDirectory: URL,
                            fileManager: FileManager = .default) throws -> SiteSettings
```

Behaviour identical to today's `load()`: absent file → `SiteSettings()`; decode
failure → `SiteSettings()`; I/O error reading an existing file → throws. The
actor's `load()` becomes `try Self.read(from:fileManager:)`.

### 2. `SiteStore.Site` — resolve override in `make()` (Core)

- `Site.name` changes `let` → `var` (mutable via rename; `id`/`packageURL` stay `let`).
- `make()` reads settings via `(try? SiteConfigStore.read(from: package.configURL,
  fileManager: fileManager)) ?? SiteSettings()` so a settings read never blocks
  opening a site, then resolves `name` as above.

### 3. `SiteStore.setDisplayName` — rename mutator (Core)

```swift
@discardableResult
func setDisplayName(_ name: String?, for id: String) async throws -> Site
```

1. Locate the entry; trim `name` → nil if empty (empty clears the override).
2. Load current `SiteSettings`, set `displayName`, `save()` to `settings.plist`.
3. Re-run `Site.make(package:)` to get the freshly-resolved name (handles both
   set and clear via the marker fallback), carry forward `lastSeen` +
   `bookmarkData`, replace in `sites`.
4. `persist()` + `emitChange()` — broadcasts the new name to all observers.

No-op (returns current) if `id` is unknown.

### 4. Rename UI — launcher context menu + alert (App)

`SitesLauncherView`:
- Add "Rename…" to the existing row `contextMenu` (beside "Remove from Anglesite…").
- Present a native `.alert` with a `TextField` prefilled with the current name,
  mirroring the existing remove-confirmation pattern. "Rename" calls
  `setDisplayName`; empty input clears the override back to the marker name.
- Update the launcher's local `sites` from the result so the list refreshes.

### 5. Window live-refresh (App)

`SiteWindow` holds a `@State` snapshot of `site` and already consumes
`SiteStore.changeStream()` via `observeRemoval()`. Generalize it to
`observeStoreChanges()`: on each snapshot, if the matching entry is gone →
dismiss (unchanged); otherwise refresh the `@State site` when the entry differs,
so `.navigationTitle(site.name)` and the drawer headings update live after a
rename.

## Data flow

```
Rename… (launcher) ─▶ SiteStore.setDisplayName(name, for: id)
                        ├─ SiteConfigStore.save(settings.plist)
                        ├─ Site.make()  → resolved name
                        ├─ sites[i] updated, persist(recents.json)
                        └─ emitChange() ─▶ changeStream broadcast
                                            ├─▶ launcher list (local sites updated)
                                            └─▶ open SiteWindow: observeStoreChanges
                                                 refreshes @State site → title/drawers
```

## Testing (Core, swift test)

- `Site.make()`: prefers `displayName` override; falls back when nil; falls back
  when empty/whitespace; falls back when `settings.plist` is unreadable/corrupt.
- `SiteConfigStore.read` static: parity with instance `load()` across
  absent/present/corrupt/IO-error cases.
- `SiteStore.setDisplayName`: writes plist; updates in-memory `name`; persists to
  `recents.json`; empty input clears override back to the marker name; unknown id
  is a no-op.

UI wiring (launcher alert, window observe) is exercised through the existing
app-target patterns; the testable logic lives in Core per the project's
"push logic into AnglesiteCore" rule (CLAUDE.md).

## Files touched

- `Sources/AnglesiteCore/SiteConfigStore.swift`
- `Sources/AnglesiteCore/SiteStore.swift`
- `Sources/AnglesiteApp/SitesLauncherView.swift`
- `Sources/AnglesiteApp/SiteWindow.swift`
- `Tests/AnglesiteCoreTests/…` (Site.make / SiteConfigStore.read / setDisplayName)

## Out of scope

- A `Get Info`-style settings pane (rename is the only `SiteSettings` consumer today).
- Additional `SiteSettings` fields (YAGNI).
