# File menu: New Site / Open Site / Open Recent

**Date:** 2026-06-16
**Status:** Design approved
**Branch base:** Stacked on `#188` (`fix/188-orphaned-site-window`) — depends on `SiteStore.changeStream()`, which is not yet in `main`.

## Problem

The app's File menu has no New/Open commands. Creating and importing a site is only
reachable through the **"Add Site"** menu in the launcher footer
(`SitesLauncherView.swift`): *"Create new site…"* (`presentNewSite()`) and *"Import
existing site…"* (`openFolder()`). These actions are unavailable from a focused site
window, and there is no keyboard path (`⌘N` / `⌘O`) to them.

Because the app declares `WindowGroup(for: String.self)`, SwiftUI also *auto-generates*
a "New Window" `⌘N` item we don't want.

## Goals

- Add **New Site** (`⌘N`), **Open Site…** (`⌘O`), and an **Open Recent ▸** submenu to
  the File menu, available from any window.
- Reuse the existing create/import logic — no duplicated registration or
  security-scoped-bookmark code.
- Keep the launcher footer's "Add Site" menu working, sharing the same code path.

## Non-goals

- No true most-recently-used *history* with its own persistence. "Open Recent" lists
  the registered sites from `SiteStore`, capped and sorted (see below).
- No changes to the Edit/View/Help menus, the wizard UI, or `SiteWindow`.
- No "Open Recent → Clear Menu" affordance (the list is derived from the registry, not
  a separate history).

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Invocation from a site window | **Open Site… runs anywhere; New Site routes to the launcher.** |
| Open scope | **Folder picker + Open Recent submenu.** |
| Labels / shortcuts | **"New Site" `⌘N`, "Open Site…" `⌘O`** (matches codebase "site" terminology). |
| Launcher footer | **Keep it, share logic.** |
| Open Recent contents | **All registered sites**, sorted by `lastSeen` desc, capped at 10. |
| Selection logic location | **AnglesiteCore** (pure, unit-testable). |

## Architecture

Five units, each with a single responsibility.

### 1. Menu structure — `AnglesiteApp.swift`

Replace the auto-generated New section so our `⌘N` doesn't collide with the
`WindowGroup`-generated "New Window":

```swift
CommandGroup(replacing: .newItem) {
    Button("New Site") {
        openWindow(id: "sites")              // ensure the launcher exists to host the wizard
        WindowRouter.shared.requestNewSite()
    }
    .keyboardShortcut("n")                    // ⌘N

    Button("Open Site…") {
        Task { await openSiteFromMenu() }     // NSOpenPanel — window-independent
    }
    .keyboardShortcut("o")                    // ⌘O

    Menu("Open Recent") {
        ForEach(recent.sites) { site in
            Button(site.name) { openWindow(value: site.id) }
                .disabled(!site.isValid)
        }
        if recent.sites.isEmpty {
            Button("No Recent Sites") {}.disabled(true)
        }
    }
}
```

State held on the `App` struct: `@State private var recent = RecentSitesModel.shared`.
`openSiteFromMenu()` is a small `@MainActor` helper on the `App` (or a free function)
that calls `SiteActions.pickAndRegisterSite()` and opens the result, surfacing failures
via `NSAlert`.

### 2. Shared import logic — `Sources/AnglesiteApp/SiteActions.swift` (new)

Extract the fiddly panel → register → bookmark sequence out of
`SitesLauncherView.openFolder()`:

```swift
@MainActor
enum SiteActions {
    /// NSOpenPanel → SiteStore.add → (MAS) security-scoped bookmark.
    /// Returns the new site, or nil if the user cancelled. Throws on add failure.
    static func pickAndRegisterSite() async throws -> SiteStore.Site? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an Anglesite project directory."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let site = try await SiteStore.shared.add(url)
        #if ANGLESITE_MAS
        let bookmark = try SecurityScopedBookmark.create(for: url)
        try await SiteStore.shared.setBookmark(bookmark, for: site.id)
        #endif
        return site
    }
}
```

Callers own their own window + error presentation:

- **Launcher** `openFolder()` → `pickAndRegisterSite()` → `refreshSites()` →
  `open(site:)` (its existing dismiss-on-open). Errors → `loadError` (inline, unchanged).
- **Menu** `openSiteFromMenu()` → `pickAndRegisterSite()` →
  `openWindow(value: site.id)`. Errors → `NSAlert`.

This keeps the MAS bookmark dance in exactly one place.

### 3. New-Site routing — `WindowRouter` (AnglesiteIntents)

Mirror the existing `requestOpen(siteID:)` signal:

```swift
public var newSiteRequested = false
public func requestNewSite() { newSiteRequested = true }
```

`SitesLauncherView` observes it (`@State private var router = WindowRouter.shared`) and
triggers its **existing** `presentNewSite()`:

- `.onChange(of: router.newSiteRequested)` → **launcher already open** case. Clears the
  flag, then `presentNewSite()`.
- `onFirstAppear()` (after refresh) → **launcher just created by the menu** case
  (`.onChange` does not fire for an initial `true`). Same clear-then-present.
- `presentNewSite()` gains a guard `if showingNewSite { return }` to prevent a
  double-present race between the two paths.

The footer's "Create new site…" still calls `presentNewSite()` directly — untouched.

### 4. Recent-sites selection — `Sources/AnglesiteCore/RecentSites.swift` (new)

Pure, synchronous, unit-testable:

```swift
public enum RecentSites {
    /// Most-recently-seen first, capped. Invalid sites are included (the menu disables
    /// them) so the list matches what the launcher shows.
    public static func select(from sites: [SiteStore.Site], limit: Int = 10) -> [SiteStore.Site] {
        sites.sorted { $0.lastSeen > $1.lastSeen }.prefix(limit).map { $0 }
    }
}
```

### 5. Recent-sites observable mirror — `Sources/AnglesiteApp/RecentSitesModel.swift` (new)

Menus can't `await`, but `SiteStore` is an `actor`. This `@MainActor @Observable`
mirror gives the menu a synchronous, live-updating list:

```swift
@MainActor
@Observable
final class RecentSitesModel {
    static let shared = RecentSitesModel()
    private(set) var sites: [SiteStore.Site] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task {
            // Initial populate, then keep live via the #188 broadcast.
            try? await SiteStore.shared.load()
            sites = RecentSites.select(from: (try? await SiteStore.shared.refresh()) ?? [])
            for await snapshot in SiteStore.shared.changeStream() {
                sites = RecentSites.select(from: snapshot)
            }
        }
    }
}
```

Started once from `AppDelegate.applicationDidFinishLaunching`. The `App` struct holds
`RecentSitesModel.shared` as `@State` so SwiftUI re-evaluates the menu when `sites`
changes.

## Data flow

```
File ▸ New Site (⌘N)
  → openWindow(id:"sites") + WindowRouter.requestNewSite()
  → SitesLauncherView observes flag → presentNewSite() → wizard sheet → SiteStore.add → openWindow(value:)

File ▸ Open Site… (⌘O)
  → SiteActions.pickAndRegisterSite() → openWindow(value: site.id)   [error → NSAlert]

File ▸ Open Recent ▸ <site>
  → openWindow(value: site.id)

SiteStore mutations (add/remove/refresh)
  → changeStream() snapshot → RecentSites.select → RecentSitesModel.sites → menu re-renders
```

## Error handling

- **Open Site… cancel** → no-op (`pickAndRegisterSite` returns nil).
- **Open Site… add failure** → `NSAlert` (menu) / `loadError` (launcher).
- **New Site, plugin missing / theme load failure** → existing `presentNewSite()`
  behavior (`loadError` in the launcher) — unchanged.
- **Open Recent on an invalid site** → button disabled; cannot be invoked.
- **Open Recent when empty** → disabled "No Recent Sites" placeholder.

## MAS / sandbox

- `pickAndRegisterSite()` keeps the `#if ANGLESITE_MAS` bookmark minting, so Open Site…
  works sandboxed from any window.
- New Site continues through `presentNewSite()`, which already handles the sites-root
  scoped grant.
- Open Recent only calls `openWindow(value:)`; `SiteWindow` resolves the per-site
  bookmark itself, as today.

## Testing

- **TDD unit (AnglesiteCore):** `RecentSites.select` — ordering by `lastSeen`, cap at
  `limit`, empty input, fewer-than-limit, stable mapping. This is the only pure unit and
  the only part covered by `swift test` (there is no app-target unit suite).
- **Build:** `xcodebuild -scheme Anglesite` **and** `-scheme AnglesiteMAS` (exercises the
  `#if ANGLESITE_MAS` bookmark path in `SiteActions`).
- **Manual smoke:**
  - `⌘N` from a site window → launcher opens, wizard appears.
  - `⌘O` from the launcher and from a site window → folder picker → site opens.
  - Open Recent lists sites, reopens on click, disables invalid entries, updates live
    after add/remove.

## Files

| File | Change |
|---|---|
| `Sources/AnglesiteApp/AnglesiteApp.swift` | `CommandGroup(replacing: .newItem)`; hold `RecentSitesModel`; `openSiteFromMenu()`. |
| `Sources/AnglesiteApp/SiteActions.swift` | **New** — `pickAndRegisterSite()`. |
| `Sources/AnglesiteApp/RecentSitesModel.swift` | **New** — `@MainActor @Observable` mirror. |
| `Sources/AnglesiteCore/RecentSites.swift` | **New** — pure `select(from:limit:)`. |
| `Sources/AnglesiteIntents/WindowRouter.swift` | Add `newSiteRequested` / `requestNewSite()`. |
| `Sources/AnglesiteApp/SitesLauncherView.swift` | `openFolder()` delegates to `SiteActions`; observe `newSiteRequested`; guard in `presentNewSite()`. |
| `Tests/AnglesiteCoreTests/RecentSitesTests.swift` | **New** — unit tests for `select`. |
| `Sources/AnglesiteApp/AnglesiteApp.swift` (AppDelegate) | `RecentSitesModel.shared.start()` in `applicationDidFinishLaunching`. |
