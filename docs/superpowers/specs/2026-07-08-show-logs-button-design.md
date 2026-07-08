# "Show Logs" button on loading/updating screens (#560)

**Issue:** [#560](https://github.com/Anglesite/Anglesite-app/issues/560) — while the Astro dev
server boots or npm dependencies update, the site window shows a progress bar. Techies and people
learning want to look under the hood: add a "Show Logs" affordance that opens the running log in a
Console.app-style view.

## Context

- Both loading screens are the **same view**: `SiteWindow.previewPane(for:)`'s `.starting` case
  renders `StartupProgressView`, with the title keyed off `PreviewModel.isUpdatingDependencies`
  (`Sources/AnglesiteApp/SiteWindow.swift`).
- The Console.app-style viewer **already exists**: `DebugPaneView` (source/stream filters, search,
  pause, copy, save) in the top-level `Window("Anglesite Debug", id: "debug")`
  (`Sources/AnglesiteApp/AnglesiteApp.swift`), live-tailing `LogCenter.shared`, which every
  subprocess already streams into ("logs are sacred").
- The debug pane's *menu item* (⌥⌘D) is gated by `DebugPaneVisibility` (Debug build / Settings
  toggle / Option at launch), but the window scene is always registered.

## Design

Pure wiring — no new log infrastructure:

1. `StartupProgressView` gains `let onShowLogs: (() -> Void)?` (defaulting to `nil`) and renders a
   small borderless "Show Logs" button beneath the status message when the closure is present.
2. `SiteWindow`'s `.starting` case passes `onShowLogs: { openWindow(id: "debug") }` —
   `@Environment(\.openWindow)` is already in scope. SwiftUI dedupes `openWindow(id:)`, so a
   second press focuses the existing window.
3. The button opens the log window **unconditionally**, independent of the `DebugPaneVisibility`
   menu gate: the issue's whole point is surfacing logs to non-developers, and the gate only
   governs the menu item's discoverability, not the pane's existence.

One placement covers both screens the issue names (dev-server start and dependency update) because
they share the `.starting` case.

## Alternatives rejected

- **In-window log drawer** (split view under the progress bar): duplicates `DebugPaneView` or
  requires extracting/refactoring it; far more scope for the same information.
- **Launch Console.app**: app subprocess logs live in `LogCenter`'s in-memory ring buffer, not the
  unified system log, so Console.app would show nothing useful.
- **Pre-filtering the pane to `container:<siteID>`**: would require converting the plain
  `Window(id: "debug")` into a value-presented `WindowGroup` and touching the existing ⌥⌘D path.
  The pane already has a Source picker; YAGNI for now.

## Testing

The change is SwiftUI view wiring with no new logic (no model changes, no branching beyond
`if let`). There is no existing view-test harness for `StartupProgressView`/`DebugPaneView`;
verification is `xcodebuild` (app links), `swift test` (no regressions), and a GUI check of the
loading screen.

## Follow-up (out of scope)

The `.failed` preview state (which shows *Retry*) would also benefit from a "Show Logs" button —
failures are when logs matter most. Tracked separately rather than widening this change.
