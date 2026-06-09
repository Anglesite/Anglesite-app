# Health badge — deploy-readiness indicator

**Status:** approved — ready for implementation
**Tracks:** [#31](https://github.com/Anglesite/Anglesite-app/issues/31) — Phase 9 step 2 of [build-plan.md](../build-plan.md#phase-9--v1-multi-site--drag-drop-images)
**Date:** 2026-05-26

## Motivation

Issue #31 originally proposed a per-site health badge backed by polling `/anglesite:check` every 5 minutes. That skill spawns Claude with the full audit checklist (build + a11y + WCAG + Cloudflare API queries) — running it on a 5-minute timer per open window would burn tokens, wall-clock minutes, and CPU for state that rarely changes between owner actions.

The cheap, deterministic signal we already produce is `scripts/pre-deploy-check.ts --json`, wired into the app by Phase 6's `PreDeployCheck.swift`. It runs in seconds and answers exactly the question an owner glances at the badge for: *"would my site pass the gate the Deploy button enforces?"* The badge therefore reflects **deploy readiness**, not the broader Claude audit. The Claude audit remains available via the `Ask Claude` button in the popover for owners who want the human-readable rollup.

## Behavior

One badge per `SiteWindow`, placed in the header row to the left of the `Chat` button. It is a circular status indicator that takes one of four states:

| State      | Color   | Meaning                                                                 |
|------------|---------|-------------------------------------------------------------------------|
| `unknown`  | gray    | No scan has run yet this session. Initial state for a freshly-opened window. |
| `clean`    | green   | Most recent scan: no `ScanFailure`, no `ScanWarning`.                   |
| `warnings` | yellow  | Most recent scan: zero failures, one or more warnings.                  |
| `failures` | red     | Most recent scan: one or more failures (deploy would be blocked).       |

Clicking the badge presents an `NSPopover` anchored to it. The popover contains:

- A header line with the state and a relative timestamp ("Checked 4 min ago" / "Never checked").
- A bulleted list of `PreDeployCheck.ScanFailure` and `PreDeployCheck.ScanWarning` items from the cached `ScanReport`. Empty in the `clean` state — the popover then shows a "No issues found in the most recent scan" line.
- A `Recheck` button that runs `npm run build` followed by `pre-deploy-check.ts --json` again, streams output via `LogCenter` under the source `health:<siteID>`, and updates the badge from the new result.
- An `Ask Claude` button that opens the chat panel and submits `/anglesite:check` through the existing skill quick-action path.

Refresh triggers are exactly two:
1. `DeployModel` completing a deploy (`.succeeded` or `.blocked` — both expose a fresh `ScanReport`). `SiteWindow` mirrors that report into `HealthModel` so the badge stays in sync without the owner doing anything.
2. The owner clicks `Recheck` in the popover.

There is **no background polling.** Energy state, window visibility, and `thermalState` checks from the original issue scope are unnecessary once the timer is removed.

## Architecture

```
SiteWindow.mainPane header
  └─ HealthBadgeView (button + circle indicator + popover)
        └─ HealthModel (@Observable, per-window @State)
              ├─ phase: .idle | .running | .result(ScanReport) | .failed(reason)
              ├─ lastCheckedAt: Date?
              ├─ recheck(siteID:siteDirectory:) -> Task
              │     └─ runner.run(...) -> PreDeployCheck.ScanReport
              └─ ingestDeployResult(_:) // mirror DeployModel's scan
```

`HealthModel` lives in the `AnglesiteApp` module (UI-adjacent state, following the existing `PreviewModel` / `DeployModel` pattern — `@Observable`, `@MainActor`, held as `@State` by `SiteWindow`). It owns no process directly: the scan runner is an injectable protocol so tests can stub it without touching `Process`.

```swift
protocol HealthCheckRunner: Sendable {
    func run(siteID: String, siteDirectory: URL) async throws -> PreDeployCheck.ScanReport
}
```

The production runner (a single concrete struct in `AnglesiteApp`) composes existing primitives — `ProcessSupervisor.shared` to spawn `npm run build` then `pre-deploy-check.ts --json`, `LogCenter` for streaming, the existing `PreDeployCheck` JSON parser. No new process management code; no MCP client (the badge doesn't need one).

`DeployModel` gains one small addition: an `onScanComplete: ((PreDeployCheck.ScanReport) -> Void)?` callback that fires whenever the deploy pipeline finishes a scan, regardless of whether the deploy itself succeeded, blocked, or failed afterward. `SiteWindow` wires `deploy.onScanComplete = { [weak health] r in health?.ingestDeployResult(r) }` in its `loadAndStart`. The two models stay independent.

## Data flow

```
Recheck flow:
  HealthBadgeView click → HealthModel.recheck()
    → HealthCheckRunner.run() → ProcessSupervisor spawn
    → npm run build (LogCenter source: "health:<siteID>:build")
    → pre-deploy-check.ts --json (LogCenter source: "health:<siteID>:scan")
    → JSON → PreDeployCheck.ScanReport
    → HealthModel.phase = .result(report); lastCheckedAt = Date()

Deploy-mirror flow:
  DeployModel.deploy(...) → scan step completes
    → onScanComplete(report) → HealthModel.ingestDeployResult(report)
    → HealthModel.phase = .result(report); lastCheckedAt = Date()
```

`HealthModel` exposes a computed `badgeState: BadgeState` derived from `phase` and the report counts. The view binds to that single property — it doesn't need to peek at `phase` directly.

## Error handling

- **Build failure** (non-zero exit before the scan can run): `phase = .failed(.buildFailed(message))`, badge renders red with an "Unable to check — build failed" popover. The owner's site state is unchanged.
- **Scan crash** (script throws / non-JSON output): `phase = .failed(.scanFailed(message))`, same red treatment with the relevant log excerpt in the popover.
- **Recheck while one is in flight:** the in-flight `Task` is cancelled (matches `DeployModel.deploy`'s pattern). The new run replaces the previous one.
- **App quit:** supervised processes drain through `ProcessSupervisor.shutdownAll` — no new wiring needed.
- **Missing `npm` / vendored node:** the existing `PreviewSession` shape handles this with `.failed("dependencies not installed — run npm install")`; we reuse the same diagnostic text so the badge popover surfaces the same advice the preview pane does.

## Testing

- **`HealthModelTests`** (new). The state-machine logic is pure over the injectable `HealthCheckRunner` protocol; the implementation plan will decide whether that lives in `HealthModel` directly (tested via a new `AnglesiteAppTests` bundle) or extracted to a small `HealthEngine` in `AnglesiteCore` (tested in the existing `AnglesiteCoreTests` target, matching how `PreviewSession` underpins `PreviewModel`). Either way, inject a `MockHealthCheckRunner` that returns canned `ScanReport`s or throws. Assert:
  - Initial state is `.idle` with `lastCheckedAt == nil`, `badgeState == .unknown`.
  - `recheck` transitions `.idle → .running → .result(report)`; `lastCheckedAt` becomes non-nil.
  - `recheck` while running cancels the prior task; only the latest result lands.
  - Runner throws → `.failed(reason)`, `badgeState == .failures`.
  - `ingestDeployResult` matches `recheck`'s state-transition behavior.
  - `badgeState` mapping: empty report → `.clean`; warnings-only → `.warnings`; any failure → `.failures`.

- **`HealthBadgeViewTests`**: snapshot-style not required; one ViewInspector-style test that the click target presents the popover and that the popover's `Recheck` button calls through is enough.

- **No real-process integration test.** Running `npm run build` is slow, fragile in CI, and already covered by manual smoke via `scripts/create-smoke-fixture.sh`. That script's documented checklist gets a fifth step: *"Click the health badge → Recheck → badge transitions through running → result; report matches the deploy gate."*

## Out of scope (deferred)

- `astro check` / TypeScript integration. The pre-deploy scan is sufficient signal for v1; layering `astro check` in is a follow-up if owners report missing classes of breakage.
- Per-site polling, energy/thermal gating, window-visibility pausing. All three from the original #31 scope are obviated by the "no timer" decision.
- Notifications when the badge changes state in the background. The badge updates on owner action only; passive surfacing belongs in a future "site health timeline" feature, not v1.
- Click-through to a granular log/history view of past scans. The popover always shows *the latest* scan only. The `LogCenter`/Debug pane already retains the full transcript for owners who want it.
