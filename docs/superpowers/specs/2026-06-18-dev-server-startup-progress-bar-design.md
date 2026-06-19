# Dev-server startup progress bar

**Date:** 2026-06-18
**Status:** Approved design — ready for implementation plan
**Branch:** `feature/startup-progress-bar`

## Problem

When a site window opens its live preview, the dev server (`astro dev`) takes a few
seconds to boot. Today the UI shows only an indeterminate spinner —
`ProgressView("Starting dev server for <name>…")` at `SiteWindow.swift:258` — which
gives the owner no sense of how far along startup is or what it is doing.

Replace it with a **determinate progress bar** that:

1. advances through the real startup milestones,
2. creeps smoothly between milestones using how long each segment took last time, and
3. shows a short phase message underneath the bar as the server loads.

## Goals / non-goals

**Goals**
- Determinate bar that reflects actual startup phases.
- Smooth, never-frozen fill paced by the previous successful startup's per-segment
  timing (the original "estimate from last startup" ask), with a built-in default
  profile on first run.
- A curated phase message under the bar.

**Non-goals**
- No numeric ETA or "step N of M" text (curated phase message only).
- No raw Astro log text surfaced as the message (milestone-driven, curated strings).
- No changes to readiness detection, the failure UI, or the `SiteRuntimeState` enum.
- No `npm install` phase — dependencies must already exist for `astro dev` to launch
  (`resolveAstroCommand` returns `.unavailable` → `.failed` otherwise), so install is
  not part of this startup path.

## Background: the startup path

From `LocalSiteRuntime.start(siteID:siteDirectory:)`:

1. `setState(.starting(siteID:))`.
2. `AstroDevServer.start(...)` spawns `node …/.bin/astro dev`, then races: a `Local
   http://…` line on the `astro:<siteID>` stdout stream **and** an HTTP probe of that
   URL succeeding, vs. early exit, vs. a 30s `readyTimeout`.
3. Best-effort MCP client spawn (`startMCPClient`).
4. Best-effort content-graph population (`populateContentGraph` → `list_content`).
5. `setState(.ready(siteID:, url:))`, or `.failed(...)` on error.

The preview pane shows the loading indicator for the whole `.starting` window — i.e.
through steps 2–4 — until `.ready`.

Two facts the design reuses:
- The dev-server's ready URL is printed on the `astro:<siteID>` **stdout** stream and
  parsed by `AstroDevServer.parseReadyURL(_:)` — a `public static` function.
- Every subprocess line flows through `LogCenter.shared`, tagged with `source`
  (`"astro:<siteID>"`) and `stream` (`.stdout`/`.stderr`), and is subscribable.

## Architecture — UI-only, core untouched

No changes to `AnglesiteCore`'s runtime types or the `SiteRuntimeState` enum. A new
view model derives all progress from two signals the app already exposes:

- the `SiteRuntimeState` stream that `PreviewModel` already mirrors — anchors
  `launching` (`.starting`), `ready` (`.ready`), and `error` (`.failed`);
- `LogCenter` lines tagged `astro:<siteID>` — anchors `building` (first dev-server
  stdout line) and `connecting` (a line where `parseReadyURL` matches).

This keeps the change inside the app layer ("the app is a host"), avoids widening the
shared state enum (no churn in the many `case .starting` matchers across views and
tests), and is fully unit-testable without a hosted app target.

### Components

**`StartupPhase` (enum, AnglesiteApp)**
`launching`, `building`, `connecting`, `ready`, `error`. Each non-terminal phase has a
target fill cap and a curated message.

**`StartupProgressModel` (`@Observable @MainActor`, AnglesiteApp)**
Owns the displayed `fraction: Double` (0…1), the current `StartupPhase`, and `message:
String`. Responsibilities:
- Subscribe to the `SiteRuntimeState` stream and to `LogCenter` filtered to
  `astro:<siteID>` (`.stdout`).
- Map signals → phase anchors (table below).
- Run a `MainActor` timer that eases `fraction` toward the current phase's cap, paced
  by the expected segment duration from `StartupTimingStore`. The timer **never reaches
  the cap on its own** — only a real anchor advances the phase and unlocks the next
  cap. On overrun, ease-out asymptotically toward the cap so the bar keeps inching but
  never completes early or freezes.
- Record per-segment elapsed times; on `.ready`, write them back to the store.
- Reset on `.failed` / teardown (the existing error pane takes over).

**`StartupTimingStore` (AnglesiteCore, backed by `AppSettings`/UserDefaults)**
Persists the per-segment durations of the last *successful* startup, keyed per site
(e.g. `anglesite.startupTiming.<siteID>`). Provides:
- `profile(for siteID:) -> StartupProfile` — last successful per-segment durations, or
  a built-in default profile (calibrated to the default template) when no history
  exists or the stored value is missing/corrupt.
- `record(siteID:, segments:)` — persist a completed successful startup.

Lives in `AnglesiteCore` because it is plain, testable, and persistence-oriented; the
default profile constant lives alongside it.

### Milestone → fraction → message

| Phase        | Anchor signal                                  | Fill cap   | Message                 |
|--------------|------------------------------------------------|------------|-------------------------|
| `launching`  | state → `.starting`                            | 0 → ~15%   | "Starting dev server…"  |
| `building`   | first `astro:<id>` `.stdout` line              | ~15 → ~55% | "Building site…"        |
| `connecting` | a log line where `parseReadyURL` matches       | ~55 → ~90% | "Connecting to preview…"|
| `ready`      | state → `.ready`                               | → 100%, fade | (preview loads)       |

The `connecting → ready` interval covers the HTTP probe plus the MCP/content-graph
tail. Caps are the *ceilings* the smooth fill asymptotes toward; the real anchor is
what crosses into the next phase and raises the ceiling.

The fraction is monotonic: it never decreases and never reaches 100% before the
`.ready` anchor.

### Persistence detail

A `StartupProfile` is the set of expected segment durations:
`launching→building`, `building→connecting`, `connecting→ready`. The model timestamps
each anchor crossing; on success it diffs consecutive timestamps into those three
segments and calls `record`. Pacing for the *next* startup reads `profile(for:)`.

The default profile is a small built-in constant (a few seconds total, weighted toward
the `building` segment) so first-run and history-less sites still animate believably.

## Error handling

- `.failed` (including the 30s `readyTimeout`, which resolves to `.failed`): the model
  stops its timer and resets; the existing error pane with the retry button at
  `SiteWindow.swift` renders unchanged. No separate timeout path is needed.
- Corrupt/missing stored timing → silently fall back to the default profile.
- A restart that re-emits a `Local …` line mid-session (supervised crash recovery) does
  not affect the bar — the model only runs while state is `.starting`; once `.ready`,
  the preview is shown and the bar is gone.

## Testing

Both new types are plain and host-independent (run under `swift test`):

- **`StartupProgressModel`** — feed a synthetic ordered sequence of `SiteRuntimeState`
  values and `LogLine`s; assert: correct phase transitions and messages; fraction is
  monotonic non-decreasing; fraction never hits 1.0 before the `.ready` anchor; on
  overrun the fraction approaches but does not pass the phase cap; reset on `.failed`.
- **`StartupTimingStore`** — round-trip `record` → `profile`; default-profile fallback
  when nothing is stored and when the stored value is corrupt; per-site key isolation.

A light view check confirms `SiteWindow`'s `.starting` branch renders the determinate
bar + message instead of the indeterminate `ProgressView`.

## UI integration

Replace the `.starting` branch at `SiteWindow.swift:258`:

```swift
case .starting:
    centeredStatus {
        StartupProgressView(model: startupProgressModel)  // determinate bar + message
    }
```

The `StartupProgressModel` is created per site window (alongside `PreviewModel`), wired
to the same runtime's state stream and `LogCenter`, and torn down with the window.
