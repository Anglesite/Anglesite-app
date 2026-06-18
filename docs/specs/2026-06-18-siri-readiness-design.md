# Siri AI Readiness Diagnostics — Design

- **Issue:** #236 (Siri AI: add local readiness diagnostics for supported workflows)
- **Date:** 2026-06-18
- **Status:** Design — pending implementation plan
- **Related:** #135 (Phase D), #232/#225 (D.1/D.2 MCP readiness), #242 (`.anglesite` package + per-site config model — foundational follow-up this design's seam migrates to)

## Summary

Add a read-only, network-free diagnostic that tells a user whether the Siri-driven
workflows can work on their Mac and for a given site. Each reported status is produced
by a **concrete probe** (not static text), every probe is **injectable** for tests, and
the work lives in `AnglesiteCore` so it is covered on CI (app-target UI stays thin).

The diagnostic is split across two surfaces following Xcode's per-project model (not
Mail's app-owned-store model — see Decisions):

- **System capabilities** → a new **"Siri AI" tab in Settings** (global, no site list).
- **Per-site readiness** → a **per-`SiteWindow` "Siri AI Readiness…" command** scoped to
  that window's site.

## Decisions (from brainstorming)

1. **UI home:** dedicated Settings tab for system capabilities (discoverable for a normal
   user, room to grow as Phase C/D land).
2. **Probe all listed capabilities, report honestly.** Capabilities the build can't fully
   exercise yet (System MCP bridge — unbuilt; Foundation Models — partially built) return
   a real `.unsupported` finding ("Not yet available in this build"), never a fake ✅ and
   never omitted. A truthful absence-detection is still a concrete probe.
3. **Per-site config follows Xcode, not Mail.** Per-site state belongs *with the site*
   (window), not in app-global Settings. This dissolves the "site picker in Settings"
   question — there is no picker; per-site readiness is a per-window surface. The deeper
   `.anglesite` package model that this implies is tracked separately as **#242** and is
   *not* a blocker for this work.
4. **No new seam type (YAGNI).** #236's per-site probes read *runtime* state (content graph,
   Spotlight index counts) keyed by `siteID`, so no persisted per-site config store and no new
   location type is introduced here. The SiteWindow already carries the site's id + directory,
   and `AppSettings.sitesRoot` already resolves `~/Sites/<name>/`. *That existing resolution* is
   the seam #242 migrates to the `.anglesite` package — #236 adds nothing for it to replace.

## Architecture

### Module placement

The shared types (`ReadinessLevel`, `ReadinessFinding`, `ReadinessProbe`,
`SiriReadinessModel`) and the probes needing only Foundation/Core APIs (OS runtime,
Foundation Models, content-graph freshness) live in **`AnglesiteCore`**. Probes that read
App-Intents / Spotlight surfaces (App Intents registration, View Annotations, Spotlight
index status, MCP bridge) live in **`AnglesiteIntents`** (which depends on Core). Both
modules are covered by CI tests; only the SwiftUI views live in the app target. The probe
arrays are assembled in `AnglesiteIntents` (the one module that can see both probe sets).

### Core types (`AnglesiteCore`)

A probe never throws; a failure is a finding. This mirrors the shipped
`HealthModel` / `HealthCheckRunner` pattern (injectable runner, `@MainActor @Observable`
model, fakeable in tests).

```swift
enum ReadinessLevel: Sendable { case ok, warning, failure, unsupported }

struct ReadinessFinding: Identifiable, Sendable {
    let id: String            // stable capability id (also the row identity)
    let title: String         // "App Intents registration"
    let level: ReadinessLevel
    let detail: String        // what the probe actually found (concrete)
    let remediation: String?  // user-actionable next step, nil if none
}

protocol ReadinessProbe: Sendable {
    var id: String { get }
    var title: String { get }
    func check() async -> ReadinessFinding
}

@MainActor @Observable
final class SiriReadinessModel {
    @ObservationIgnored private let probes: [any ReadinessProbe]
    var findings: [ReadinessFinding] = []
    var isChecking = false
    var lastChecked: Date?

    init(probes: [any ReadinessProbe]) { self.probes = probes }
    func recheck() async { /* set isChecking, run probes, collect findings, stamp lastChecked */ }
}
```

One model type, two instantiations:

- **Settings tab** constructs `SiriReadinessModel(probes: systemProbes())`.
- **SiteWindow** constructs `SiriReadinessModel(probes: siteProbes(for: location))`.

### Site identity

Site probes are keyed by `siteID: String` (the folder name). The SiteWindow already holds
the site's id + directory; `AppSettings.sitesRoot` resolves `~/Sites/<name>/`. No new type
is added. #242 migrates that existing resolution to the `.anglesite` package.

## Probe inventory

All checks are **local**; none performs network I/O. The Foundation Models probe checks
*availability only* — it never runs inference.

### System probes (global)

| id | Concrete check | Levels |
|---|---|---|
| `os.runtime` | `ProcessInfo.processInfo.operatingSystemVersion` ≥ macOS 27 | ok / failure |
| `intents.registration` | `AnglesiteShortcuts.appShortcuts` non-empty; cross-check `AppIntentInfo` enumeration if the SDK exposes it | ok / warning |
| `view.annotations` | `#if compiler(>=6.4)` availability of `appEntityIdentifier` / `EntityIdentifier(for:)` | ok / unsupported |
| `foundation.models` | `SystemLanguageModel.default.availability` (`.available` / `.unavailable(reason)`) | ok / warning / unsupported |
| `mcp.bridge` | system MCP bridge registration present? (Phase D unbuilt) | unsupported |

### Site probes (scoped to a `SiteLocation`)

| id | Concrete check | Levels |
|---|---|---|
| `site.graph` | `SiteContentGraph` for the site: populated? page/post/image counts, last-update time | ok / warning |
| `site.spotlight` | `ContentSpotlightIndexer.lastIndexed` for the site; `CSSearchableIndex.default()` reachable | ok / warning |

Each probe with a non-`ok` level supplies remediation text where the user can act
(e.g. "Open this site to index its content", "Enable Apple Intelligence in System
Settings", "Upgrade to macOS 27"). `.unsupported` rows explain *why* and reference the
phase that will deliver them.

## UI

- `SiriReadinessSettingsView` — new tab in `SettingsView`'s `TabView`, alongside
  `AdvancedSettingsView`. Renders system findings, a "Re-check" button, and a
  "Last checked" timestamp.
- `SiteReadinessCommand` / sheet — a `SiteWindow` command "Siri AI Readiness…" presenting
  the site-scoped findings for that window's site.
- `ReadinessRow` — shared SwiftUI row: status glyph (✅ ok / ⚠️ warning / ❌ failure /
  ⊘ unsupported) + title + detail + optional remediation.

## Build / MAS differences

- Foundation Models probe runs on both targets (MAS always uses Foundation Models).
- The Settings tab needs no filesystem access (global only) — sandbox-safe.
- Per-site probes run from a `SiteWindow`, which already holds the per-site
  security-scoped bookmark grant on MAS.
- `#if ANGLESITE_MAS` only where strictly required.

## Testing

- **Per probe:** unit tests with injected fakes (fake content graph, fake Spotlight
  indexer exposing `lastIndexed`, fake availability source, fake OS-version source).
- **`SiriReadinessModel`:** stub probes returning canned findings → assert aggregation,
  `isChecking` true→false transition, `lastChecked` stamped.
- **Registry:** probe ids are unique and the known set is non-empty.
- Logic split across `AnglesiteCore` + `AnglesiteIntents` (both CI-covered). New tests use
  Swift Testing (`@Test`) per the suite migration (#74). UI kept thin; an `xcodebuild` link
  check on both schemes confirms the `.app` builds with the new views.

## Acceptance-criteria mapping (#236)

- *User can open the app and determine whether Siri workflows should work for the current
  site* → Settings tab (system) + per-window sheet (current site).
- *Each reported status is backed by a concrete probe rather than static text* → every
  finding is produced by a `ReadinessProbe.check()`.
- *Testable with injectable/fake probes* → `ReadinessProbe` protocol + DI into the model.
- *Does not require network access* → all probes local; FM probe checks availability only,
  never runs inference.

## Out of scope

- The `.anglesite` package + per-site config model (#242).
- Predicting Apple's regional Siri rollout (issue explicitly excludes this).
- System MCP bridge implementation (Phase D #164/#101) — this design only *reports* its
  absence; the probe upgrades to richer results when the bridge lands, with no UI change.
- Foundation Models *inference* wiring (#105) — only availability is probed here.
