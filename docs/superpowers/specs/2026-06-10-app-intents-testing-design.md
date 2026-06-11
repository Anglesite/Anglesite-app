# App Intents Testing framework adoption (#104)

**Status:** Design — approved for planning
**Date:** 2026-06-10
**Issues:** #104
**Builds on:** #122 (Phase B intents — landed as `74a08a2`)
**Foundation for:** #101 (system MCP), #102 (Spotlight semantic index), #103 (View Annotations)

## Goal

Give the four App Intents shipped in #122 (`DeploySiteIntent`, `BackupSiteIntent`,
`AuditSiteIntent`, `OpenSiteIntent`) and `SiteEntityQuery` regression coverage through
the macOS 27 App Intents Testing framework, running under `swift test` in CI alongside
the existing 270-test suite. Coverage targets the acceptance criteria from #104:

- Entity resolution: exact id, fuzzy name, ambiguous-multi (picker case), single-site
  auto-select.
- Each intent end-to-end with injected fake operations, asserting on `Result→dialog`
  mapping plus per-intent specifics (deploy confirmation, audit `ReturnsValue`,
  open's `WindowRouter` side-effect).
- Audit→deploy chaining at the technical contract level (audit returns a usable
  `SiteEntity` for deploy to consume).

## Non-goals

- Not a UI automation suite. Shortcuts.app and Siri voice continue to be exercised
  manually as in the #122 smoke checklist.
- Not a refactor of the command actors themselves (`DeployCommand` /
  `BackupCommand` / `AuditCommand`) — only the seams above them.
- Not a fix for the AppleScript-quit drain timing flagged in the #122 smoke (separate
  issue if it recurs).
- Not testing of `requestConfirmation` UI presentation — only that it's invoked before
  the deploy path runs (mocked under test).

## Approach

Extract the App Intents code (`SiteEntity`, `SiteEntityQuery`, the four
intents, `AnglesiteShortcuts`, `WindowRouter`) from the app target into a new
SwiftPM library target `AnglesiteIntents`. The new library + a new
`AnglesiteIntentsTests` target both compile under `swift test`, so CI exercises
them automatically. Intent dependencies are wired through Apple's `@Dependency`
property wrapper, with a public `bootstrap()` entry point that the app target
calls at launch — same entry point that #101's system MCP entry will reuse from
a non-UI process.

*Alternatives considered:*

- **Xcode-only test target** (under `Anglesite.xcodeproj`). Rejected: would not run
  under `swift test` and would require a new CI lane. The acceptance criteria
  explicitly prefers `swift test` integration where possible.
- **Hybrid (SPM for query/dialog, Xcode for intents)**. Rejected: two test targets
  to maintain, only partial CI coverage of the intents themselves.
- **Initializer injection** instead of `@Dependency`. Rejected: `AppIntent` types
  aren't designed for user-constructed runtime instantiation, and the same fakes
  would need a separate registration path when #101 lands.
- **`@TaskLocal` scoped per-test**. Rejected: introduces a pattern the codebase
  doesn't use anywhere else; overkill for one feature.

## Module boundary

### New SwiftPM library `AnglesiteIntents`

Moves from `Sources/AnglesiteApp/Intents/` into `Sources/AnglesiteIntents/`:

| File | Reason |
|---|---|
| `SiteEntity.swift` | Pure value type + entity query — testable in isolation. |
| `SiteIntents.swift` | The four intent structs (subject of the tests). |
| `AnglesiteShortcuts.swift` | `AppShortcutsProvider` — depends on the intents. |
| `WindowRouter.swift` (just the class) | Used by `OpenSiteIntent`. Split file: `WindowRouter` class moves; `SitesWindowRoot` view stays in app target (uses `OpenWindowAction` / `WindowGroup(for:)` scene infra). |

**Library dependencies:** `AnglesiteCore`, system `AppIntents`, `Observation`. Does
**not** depend on SwiftUI, AppKit, or AnglesiteBridge — keeps the test binary minimal.

**App target now depends on:** `AnglesiteCore`, `AnglesiteBridge`, `AnglesiteIntents`.

### `SiteOperationsService` in `AnglesiteCore`

Extract a protocol over `SiteOperations`'s four entry points:

```swift
public protocol SiteOperationsService: Sendable {
    func site(id: String) async -> SiteStore.Site?
    func deploy(site: SiteStore.Site) async -> DeployCommand.Result
    func backup(site: SiteStore.Site) async -> BackupCommand.Result
    func audit(site: SiteStore.Site) async -> AuditCommand.Result
}
extension SiteOperations: SiteOperationsService {}
```

`@Dependency` registers/resolves on the protocol, so test fakes substitute trivially.
The existing `SiteOperationsTests` continue to test the concrete `SiteOperations` via
`CommandFactory`; the new intent tests use a thin `FakeOperations` conforming to the
protocol.

## `@Dependency` wiring

### Bootstrap entry point

New `Sources/AnglesiteIntents/Bootstrap.swift`:

```swift
public enum AnglesiteIntents {
    /// Idempotent. Called once from AppDelegate at launch today; reused by #101's
    /// system MCP entry from a non-UI process.
    public static func bootstrap() {
        AppDependencyManager.shared.add { () -> any SiteOperationsService in
            SiteOperations(factory: LiveCommandFactory())
        }
    }
}
```

`AppDelegate.applicationDidFinishLaunching` calls `AnglesiteIntents.bootstrap()`
alongside the existing npm-cache prime.

### Intent refactor

Each of the four intents replaces `let ops = SiteOperations()` with:

```swift
@Dependency private var ops: any SiteOperationsService
```

`@Dependency` is lazy — resolves from `AppDependencyManager.shared` on first access.
Intent struct stays `init()`-trivial (`AppIntent` requirement). Tests register a fake
*after* the intent struct is constructed.

### Test registration

Each suite's `init()` registers a fake using the stored-instance form (not the
closure form):

```swift
@Suite("AppIntents", .serialized) struct AppIntentsTests {
    @Suite struct DeploySiteIntentTests {
        let fake = FakeOperations()
        init() {
            AppDependencyManager.shared.add(fake)
        }
        // ...
    }
}
```

The `.serialized` trait on the root `AppIntentsTests` suite ensures cross-suite
serialization, so `AppDependencyManager.shared` and `WindowRouter.shared` are mutated
by exactly one test at a time even under `swift test --parallel`.

## Test coverage

`AnglesiteIntentsTests`: ~19 tests across 7 suites, all children of the
`.serialized` root suite.

### `SiteEntityQueryTests` — 8 tests

Requires a small `SiteEntityQuery` refactor: `init(store: SiteStore = .shared)`.
Production stays no-arg (system requires `defaultQuery = SiteEntityQuery()`); tests
pass a throwaway store.

| Test | Asserts |
|---|---|
| `resolvesExactId` | `entities(for: ["s1"])` returns only `s1`. |
| `unknownIdReturnsEmpty` | `entities(for: ["nope"])` → `[]`. |
| `fuzzyMatchCaseInsensitive` | `entities(matching: "PORT")` finds `Portfolio`. |
| `fuzzyNoMatchReturnsEmpty` | `entities(matching: "xyz")` → `[]`. |
| `fuzzyAmbiguousReturnsAll` | `entities(matching: "site")` returns both `MySite` and `OldSite` (picker path). |
| `defaultResultAutoSelectsLone` | One site registered → `defaultResult()` returns it. |
| `defaultResultNilOnEmpty` | Zero sites → `nil`. |
| `defaultResultNilOnAmbiguous` | Two+ sites → `nil` (forces picker). |

### Intent end-to-end suites — 9 tests

| Suite | Tests |
|---|---|
| `DeploySiteIntentTests` | `succeedsAndReportsDeployedURL`, `blockedSurfacesPreDeployFailure`, `failureSurfacesReason` |
| `BackupSiteIntentTests` | `succeededReportsShortSHAAndRemote`, `noChangesReportsCleanly`, `failureSurfacesReason` |
| `AuditSiteIntentTests` | `reportsFindingCountsBySeverity`, `returnsSiteValueForChaining` |
| `OpenSiteIntentTests` | `setsWindowRouterRequestedToSiteID` |

Each test calls `try await intent.perform()` and asserts on the returned dialog
string + (for audit) the `ReturnsValue<SiteEntity>` payload. The `FakeOperations`
records the call and vends a configurable `Result`.

### `IntentChainingTests` — 1 test

| Test | Asserts |
|---|---|
| `auditOutputFlowsIntoDeploy` | Runs `AuditSiteIntent.perform()`, takes the returned `SiteEntity`, sets it on a new `DeploySiteIntent.site`, runs `perform()`. Verifies the technical contract that audit's `ReturnsValue<SiteEntity>` is consumable by deploy. (The Shortcuts.app editor compose UI is not a unit-testable seam.) |

### `AnglesiteShortcutsTests` — 1 test

| Test | Asserts |
|---|---|
| `providerListsThreeSiriIntents` | `AnglesiteShortcuts.appShortcuts` contains entries for Deploy / Backup / Audit (not Open, by design); phrases reference `applicationName`; `shortTitle`s match expectations. |

### Test fakes

`Tests/AnglesiteIntentsTests/Support/FakeOperations.swift`:

```swift
final class FakeOperations: SiteOperationsService {
    var siteToReturn: SiteStore.Site?
    var deployResult: DeployCommand.Result = .failed(reason: "unstubbed", exitCode: nil)
    var backupResult: BackupCommand.Result = .failed(reason: "unstubbed", exitCode: nil)
    var auditResult: AuditCommand.Result = .failed(reason: "unstubbed", exitCode: nil)
    private(set) var deployCalls: [SiteStore.Site] = []
    private(set) var backupCalls: [SiteStore.Site] = []
    private(set) var auditCalls: [SiteStore.Site] = []
    // ... protocol methods record + return configured result
}
```

Stored-instance registration (`AppDependencyManager.shared.add(fakeOps)`) means the
test reads back `fake.deployCalls` after `perform()` runs.

## CI

- New test target `AnglesiteIntentsTests` in `Package.swift` → automatically picked
  up by `swift test --parallel` (existing CI step at `.github/workflows/ci.yml:65`).
- Root `@Suite("AppIntents", .serialized)` guarantees no cross-suite races on
  `AppDependencyManager.shared` / `WindowRouter.shared`.
- Synergistic with #123 (xcodebuild CI lane). If #123 lands first, the new target's
  `project.yml` wiring is validated by CI; if not, contributors regenerate
  `Anglesite.xcodeproj` locally as documented in CLAUDE.md.

## Migration sequence

Reviewable as a stack:

1. **AnglesiteCore: extract `SiteOperationsService`.** `SiteOperations` conforms.
   No call-site changes.
2. **Create SPM library target `AnglesiteIntents`** in `Package.swift`. Depends on
   `AnglesiteCore` + system `AppIntents` framework.
3. **Move files** from `Sources/AnglesiteApp/Intents/` to `Sources/AnglesiteIntents/`.
   Split `WindowRouter.swift`: `WindowRouter` class moves; `SitesWindowRoot` view
   stays in app target.
4. **Refactor `SiteEntityQuery`** to `init(store: SiteStore = .shared)`.
5. **Switch intents** to `@Dependency private var ops: any SiteOperationsService`.
6. **Add `AnglesiteIntents.bootstrap()`** in `Sources/AnglesiteIntents/Bootstrap.swift`.
7. **`AppDelegate.applicationDidFinishLaunching`** calls `AnglesiteIntents.bootstrap()`.
8. **`project.yml`**: add `AnglesiteIntents` to `dependencies:` for both `Anglesite`
   and `AnglesiteMAS` targets. Run `xcodegen generate`.
9. **Add `Tests/AnglesiteIntentsTests/`** with `Support/FakeOperations.swift` + the
   7 suites. Add `testTarget` in `Package.swift`.

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| `@Dependency` closure form returns fresh instance per access; tests reading recorded-call state on a fake see stale data. | Use `add(fakeOps)` (stored-instance form) in tests; closure form only in production for lazy init. |
| `WindowRouter.shared` is a singleton — tests share state. | `OpenSiteIntentTests` resets `WindowRouter.shared.requested = nil` in suite `init()`. |
| `requestConfirmation` under test framework not fully documented at design time. | Spec assumes auto-confirm under test (the most likely behavior). Spike during implementation; fallback is factoring confirmation behind a `requestConfirmationHook` closure (~10 LoC). |
| AppleScript-quit drain timing flagged during #122 smoke. | Out of scope; file separate issue if it bites again. |

## Manual verification before merge

- `swift test --parallel` clean (new suite green; existing 270 tests untouched).
- Both `xcodebuild` schemes (`Anglesite`, `AnglesiteMAS`) build.
- Re-run the audit→deploy Shortcut from the #122 smoke to confirm the `@Dependency`
  refactor didn't regress runtime behavior. PR checklist item.

## Acceptance criteria (from #104)

- [x] **Entity-resolution tests cover exact/fuzzy/ambiguous/single-site cases** —
  `SiteEntityQueryTests` × 8.
- [x] **Every shipped intent has at least one system-pathway test** —
  `DeploySiteIntentTests` × 3, `BackupSiteIntentTests` × 3, `AuditSiteIntentTests`
  × 2, `OpenSiteIntentTests` × 1.
- [x] **Tests run in CI** — `AnglesiteIntentsTests` is a SPM `testTarget` picked
  up by the existing `swift test --parallel` job in
  `.github/workflows/ci.yml`.
