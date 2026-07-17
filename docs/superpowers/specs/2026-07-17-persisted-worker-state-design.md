# Persisted active-worker state + deploy diff/removal — design

**Issue:** [#709](https://github.com/Anglesite/Anglesite-app/issues/709) (700b), part of epic [#700](https://github.com/Anglesite/Anglesite-app/issues/700)
**Date:** 2026-07-17
**Status:** Proposed

## 1. Problem

`SocialWorkerProvisionCommand.provision` — the actor that provisions D1/KV/R2 resources, writes
`wrangler.toml`, and deploys a site's composed Worker — exists but has no live caller. Its
`features` parameter defaults to a hardcoded `WorkerComposition.Feature.v2` and nothing in the app
computes which workers should actually be active for a given site. There is also no per-site record
of which workers were active as of the last deploy, so there is no way to detect that a worker was
turned off and needs its Cloudflare-side route/binding torn down.

Separately, the main "Deploy" button (`DeployModel` → `DeployCommand`) only ever does a static-asset
deploy — it has never called `SocialWorkerProvisionCommand` at all. Today these are two disconnected
paths.

This issue closes both gaps: persist which workers are active, compute the effective active set on
every deploy (component-tied workers via Site Graph Explorer + settings-activated workers via a
toggle), and make the main Deploy button the single path that keeps a site's live Worker
configuration in sync with that set — activating newly-active workers and tearing down deactivated
ones — without requiring the not-yet-built Workers tab (#710) to exist first.

## 2. Scope

- Three new optional fields on `SiteSettings` (`Config/settings.plist`): `activeWorkerIDs`,
  `lastDeployedWorkerIDs`, `provisionedWorkerResources`.
- A new pure `WorkerActivation` type that computes the effective active worker-id set and diffs it
  against the last-deployed set.
- Wiring the main deploy path (`DeployModel.runDeploy`, and `SiteOperations.deploy` for the headless
  case) to compute that set and always route through `SocialWorkerProvisionCommand.provision`,
  replacing today's direct `DeployCommand.deploy` call — while preserving every existing
  `DeployCommand.deploy` behavior (route-coverage scanning, milestones, worker-name-conflict
  rename flow) that the main path already relies on (§5).
- A new `ContainerCommandRunner` so `SocialWorkerProvisionCommand`'s wrangler subcommands
  (`d1`/`kv`/`r2 create`, `d1 migrations apply`) actually execute inside the container, mirroring
  the existing `ContainerDeployExecutor` (§5) — today `provision`'s runner is stubbed to fail.
- Fixing a resource-reuse bug in `SocialWorkerProvisionCommand.readPersistedResources` that #709's
  own toggle-driven deploys would otherwise immediately expose (§6).
- Wiring `WorkerCatalogFetcher`'s `catalogURL` to the real, now-published
  `https://raw.githubusercontent.com/davidwkeith/workers/main/catalog.json` — without it, the
  effective-set computation can never see a real settings-activated worker in production. This is
  nominally #708's "wire the production catalogURL" line item; it's included here because #709 is
  inert without it (see [[dwk-workers-catalog-gaps]] memory / #708's tracking comments).

**Out of scope:**

- The Workers tab UI (#710) — this issue delivers the engine it will call.
- `WorkerComposition.Feature` → `WorkerDescriptor` migration of `generateWranglerToml` itself
  (#708). Instead, §5 uses a small, explicitly interim mapping from catalog ids to `Feature` cases,
  removed once that migration lands.
- HTTP route claims / selective `run_worker_first` composition (#746) — this issue's "removal" is
  binding/resource-level (§7), not route-level.
- Any change to `@dwk/workers` itself.

## 3. Persisted state

Extend `SiteSettings` (`Sources/AnglesiteCore/SiteConfigStore.swift`), preserving its hard
forward-compat rule that every field is `Optional`:

```swift
/// Worker catalog ids the user has manually toggled on. Component-tied workers are never
/// stored here — their active state is always recomputed live from Site Graph Explorer /
/// ImpactAnalysis (§4), so it can't drift from site content.
public var activeWorkerIDs: [String]?

/// The full effective active set (component-tied + settings-activated) as of the last
/// successful deploy — the diff baseline for reporting removals (§7).
public var lastDeployedWorkerIDs: [String]?

/// Already-provisioned Cloudflare resource ids for this site's composed Worker, durable
/// across a worker being deactivated and later reactivated (§6).
public var provisionedWorkerResources: WorkerComposition.ProvisionedResources?
```

`WorkerComposition.ProvisionedResources` (`WorkerComposition.swift:64-74`) gains `Codable`
conformance — it is already `Sendable, Equatable` with three optional `String` fields, so this is
mechanical.

## 4. Effective active set

New type, `Sources/AnglesiteCore/WorkerActivation.swift`, pure and independently testable:

```swift
public enum WorkerActivation {
    public static func effectiveActiveIDs(
        settings: SiteSettings,
        catalog: [WorkerDescriptor],
        graph: SiteGraphExplorerSnapshot?
    ) -> Set<String>

    public static func removedIDs(previous: Set<String>, next: Set<String>) -> Set<String>

    public static func mapToFeatures(_ ids: Set<String>) -> [WorkerComposition.Feature]
}
```

`effectiveActiveIDs` unions two contributions:

- **Component-tied.** For each catalog descriptor with `.binding == .componentTied(componentIDs:)`,
  include its id if `graph` is non-nil and `ImpactAnalysis.analyze(snapshot: graph, targetID:)`
  reports `hasDependents` for any of its `componentIDs`. If `graph` is `nil` (no populated
  `SiteContentGraph` for this site — the headless-deploy case, §8), component-tied contributes
  nothing. This matches `ImpactAnalysis`'s own documented bias: it may under-report, but never
  invents a dependent that isn't there.
- **Settings-activated.** `Set(settings.activeWorkerIDs ?? [])`, intersected with catalog ids that
  are actually `.settingsActivated` — **unless `catalog` is empty**, in which case
  `activeWorkerIDs` is trusted verbatim. `WorkerCatalogFetcher` already degrades network/parse
  failures to its on-disk cache, so a truly empty catalog only happens on a fresh install with no
  network and no prior successful fetch; treating that as "nothing is active" would silently
  deactivate every settings-activated worker on a transient failure, which is worse than trusting
  the last-known toggle state.

`removedIDs` is `previous.subtracting(next)` — used only to log what's being torn down (§7), not to
trigger any separate API call.

`mapToFeatures` is the interim catalog-id → `Feature` shim: `ids.compactMap { Feature(rawValue: $0) }`,
sorted into a deterministic order for stable `wrangler.toml` output. A catalog id with no matching
`Feature` case (a future, not-yet-composed worker) is silently dropped — there is nothing else this
call can do with it until #708 migrates `generateWranglerToml` to accept `[WorkerDescriptor]`
directly, at which point `mapToFeatures` is deleted and callers pass descriptors straight through.

## 5. Deploy wiring

`DeployModel.runDeploy` (`Sources/AnglesiteApp/DeployModel.swift:347-478`) is where this actually
plugs in — **not** `SiteOperations`, which the windowed deploy path bypasses entirely today
(`DeployModel` receives an already-resolved `siteDirectory`/`configDirectory` per call and talks
straight to `DeployCommand`; `SiteOperations.deploy` is a separate, thinner seam used only by App
Intents/Shortcuts, §8).

Today `runDeploy` builds `activeCommand: DeployCommand` (swapping in `ContainerDeployExecutor` when
`containerControl` is present) and calls `activeCommand.deploy(siteID:siteDirectory:configDirectory:
currentRoutes:onPreflight:onProgress:)` directly — which drives route-coverage scanning, the
milestone callbacks that feed Dock progress and the health badge, and log streaming. Routing every
deploy through `SocialWorkerProvisionCommand.provision` must not lose any of that. Its `Deployer`
closure signature (`(token:siteID:siteDirectory:) -> DeployCommand.Result`) is intentionally
minimal, so the fix is for `runDeploy` to build a `SocialWorkerProvisionCommand` per call whose
injected `deployer` closure *captures* the already-built `activeCommand` and calls its full
`deploy(...)` overload — every existing argument (configDirectory, currentRoutes, onPreflight,
onProgress) still flows through unchanged; `provision` only ever sees the final `DeployCommand.Result`.

`runDeploy`'s new sequence:

1. Load `SiteSettings` via `SiteConfigStore(configDirectory:)` (already a parameter on every
   `deploy`/`runDeploy` call — no new plumbing needed).
2. Obtain the worker catalog via `WorkerCatalogFetcher` (§2's real `catalogURL`).
3. Build a `SiteGraphExplorerSnapshot` via `SiteGraphExplorer.build` when
   `SiteContentGraph.isPopulated(siteID:)` is true; otherwise `nil`. This requires injecting the
   app's single `SiteContentGraph` instance (`AnglesiteApp.swift:11`) into `DeployModel`'s
   initializer — it doesn't have one today.
4. `WorkerActivation.effectiveActiveIDs(...)`, mapped to `[Feature]` (§4).
5. Build `SocialWorkerProvisionCommand(tokenSource: { token }, runner: containerRunner, deployer: {
   _, siteID, siteDirectory in await activeCommand.deploy(siteID:siteDirectory:configDirectory:
   currentRoutes:onPreflight:onProgress:) })` and call `.provision(siteID:siteDirectory:siteName:
   features:)` in place of today's direct `activeCommand.deploy(...)` call.
   `provision(features: [])` already degrades to an identical static-only deploy — every D1/KV/R2/
   migration block in `generateWranglerToml`/`provision` is gated on `features.contains(where:)`, so
   an empty array produces the same `wrangler.toml` `SiteScaffolder` writes at site creation — so
   this is one path, not a branch between "static" and "worker" deploys.
6. On `.succeeded`, persist `lastDeployedWorkerIDs = effectiveActiveIDs` and the returned
   `resources` to `SiteSettings` via `SiteConfigStore.save`.

**`containerRunner`** is a new `ContainerCommandRunner`, parallel to the existing
`ContainerDeployExecutor` (`DeployExecutor.swift:61-168`): both wrap
`LocalContainerControl.exec(siteID:argv:environment:workingDirectory:onOutput:)`, the same
generic in-guest exec primitive. `ContainerDeployExecutor` maps a fixed `DeployStep` to a fixed
guest argv (`npm run build` / `npx tsx scripts/pre-deploy-check.ts` / `npx wrangler deploy`);
`ContainerCommandRunner` instead maps `SocialWorkerProvisionCommand.CommandRunner`'s arbitrary
`arguments: [String]` to `["npx", "wrangler"] + arguments` and adapts `ContainerExecResult` to
`ProcessSupervisor.RunResult`. When no `containerControl` is available, `provision` falls back to
its existing stubbed `defaultRunner` (fails explicitly, matching `HostDeployExecutor`'s posture
after host-Node retirement) — no new behavior there.

**`SocialWorkerProvisionCommand.Result` gains a `.workerNameConflict(name:resources:)` case**,
mirroring `DeployCommand.Result`. Today `provision`'s internal switch collapses
`DeployCommand.Result.workerNameConflict` into a generic `.failed(reason: "Worker name … already in
use …")` (`SocialWorkerProvisionCommand.swift:176-179`) — harmless while `provision` had no live
caller, but routing every deploy through it would silently downgrade `DeployModel`'s dedicated
rename-and-retry sheet (#740: `workerNameConflictPresented`, `WorkerNameRename`,
`renameWorkerAndRetry`) to a plain failure toast. Propagating the case instead preserves that
existing UX unchanged. `SiteOperations.dialog(forSocialWorkerProvision:)`'s switch gains the
matching case.

`DeployModel.Phase` itself is unchanged (`.succeeded(url:duration:)`,
`.blocked(failures:warnings:)`, `.workerNameConflict(name:)`, `.failed(reason:exitCode:)`);
`SocialWorkerProvisionCommand.Result`'s four cases map onto it 1:1, dropping only the `resources`
payload (no UI surfaces it yet).

**Headless deploys** (App Intents/Shortcuts, via `SiteOperations.deploy`, which does *not* go
through `DeployModel`) get the same `provision`-based wiring for consistency, with `graph: nil`
(§4, §8) and whatever `containerControl` access that path already has today (unchanged by this
issue — `SiteOperations.deploy` doesn't thread one through currently, a pre-existing gap outside
this issue's scope).

## 6. Resource-id persistence fix

`SocialWorkerProvisionCommand.readPersistedResources` currently regex-scrapes the *current*
`wrangler.toml` for `database_id`/`id`/`bucket_name`. Deactivating a worker regenerates
`wrangler.toml` without that resource's binding block, so the id disappears from the file entirely.
Reactivating the worker later then finds no persisted id and calls `wrangler d1/kv/r2 … create`
again — which fails, because the resource was never deleted, just unbound, and Cloudflare rejects
creating a duplicate. This bug exists today but has never been reachable, because nothing has ever
called `provision` with a changing feature set; #709's toggle-driven deploys make it a live path for
the first time.

Fix: `readPersistedResources` becomes settings-first. Given a `SiteSettings` (loaded by the caller,
same as §5), it reads `provisionedWorkerResources` directly — durable regardless of what the current
`wrangler.toml` contains. For a site provisioned before this change (whose `Config/` has no record
yet), it falls back once to the existing file-scrape as a migration seed. After every successful
`provision()` call, the resources actually in play (freshly created or reused) are written back to
`SiteSettings.provisionedWorkerResources`, so the record only ever grows, never regresses when a
worker is deactivated.

This does not delete backing D1/KV/R2 resources on deactivation — consistent with the epic's
"respecting security, performance, cost" framing meaning route/binding teardown, not data loss.
Re-activating a worker reuses its original database/namespace/bucket and its data.

## 7. Removal mechanics

A worker present in `lastDeployedWorkerIDs` but absent from the newly computed effective set is
handled by generating `wrangler.toml` from the *new* effective set (which naturally omits its
binding/route) and deploying once. `wrangler deploy` replaces the Worker's declarative
configuration atomically, so this single deploy already un-binds and un-routes anything dropped from
config — no separate Cloudflare API call is needed. `WorkerActivation.removedIDs` (§4) is used only
to log what got torn down (via `LogCenter`, alongside the existing deploy log stream), giving the
security/cost-visibility the epic's framing asks for without a second deploy round-trip.

## 8. Headless deploy fallback

A deploy triggered without an open site window (App Intents/Shortcuts, via `SiteOperations.deploy`
directly) has no populated `SiteContentGraph` for the site, so `WorkerActivation.effectiveActiveIDs`
receives `graph: nil` and component-tied workers contribute nothing to the effective set —
settings-activated workers (`activeWorkerIDs`) are unaffected and still apply. In the worst case, a
component-tied worker that's genuinely still in use could momentarily lose its Cloudflare route
until the next windowed deploy re-affirms it (§5 always has a populated graph, since the site must
be open to click Deploy). This is an accepted, documented tradeoff — not a workaround — consistent
with `ImpactAnalysis`'s own "never invents, may under-report" contract.

## 9. Testing

- `WorkerActivation.effectiveActiveIDs` — unit tests over fixture catalogs/settings/snapshots:
  component-tied via `ImpactAnalysis` fixtures (present, absent, multiple `componentIDs`),
  settings-activated (present, stale id no longer in catalog), the nil-graph fallback, and the
  empty-catalog-trusts-`activeWorkerIDs` fallback.
- `WorkerActivation.removedIDs` / `mapToFeatures` — trivial set-diff and mapping unit tests,
  including a catalog id with no `Feature` case being dropped rather than throwing.
- `SiteConfigStore` — round-trip test for the three new fields, plus a decode test against an
  old-format `settings.plist` missing the new keys (forward-compat, matching the file's existing
  test pattern).
- `SocialWorkerProvisionCommand` — a regression test for the toggle-off-then-on-again scenario (§6):
  provision with a feature needing R2, deactivate (regenerate without it), reactivate, assert no
  second `r2 bucket create` call and the original bucket name is reused via
  `provisionedWorkerResources` rather than the file scrape.
- `SiteOperations` / `DeployModel` — wiring tests using the existing fake-`CommandFactory` pattern
  (`SiteOperationsTests`) and `DeployModel`'s existing injected-`DeployCommand` test pattern,
  asserting: empty effective set still deploys the plain static config, a non-empty set routes
  through `provision` with the right `[Feature]`, a successful deploy persists
  `lastDeployedWorkerIDs`/`provisionedWorkerResources`, and a `DeployCommand.Result
  .workerNameConflict` returned by the captured `deployer` closure still reaches
  `DeployModel.Phase.workerNameConflict` (i.e. `provision`'s new case propagates end-to-end and the
  existing rename sheet still presents) — a regression test for the collapse bug this design fixes.
- `ContainerCommandRunner` — unit tests mirroring `ContainerDeployExecutorTests`' existing pattern
  (fake `LocalContainerControl`): argv mapping (`arguments` → `npx wrangler <arguments>`), output
  streaming to `LogCenter`, cancellation, and the dead/never-booted-container error message.
- No new UI surface ships in this issue (that's #710), so no manual GUI smoke pass is owed.

## 10. Open questions / risks

- **`mapToFeatures`'s interim shim is a real, if small, encroachment on #708's territory.** It's
  scoped to a single pure function with a doc comment pointing at its own removal once #708 lands
  the `WorkerDescriptor` migration — not a fork of `generateWranglerToml` itself.
- **`WorkerCatalogFetcher`'s `catalogURL` wiring** is nominally #708 scope; done here because #709
  has no real settings-activated worker to compute against otherwise. #708's remaining scope
  (`Feature`→`WorkerDescriptor` migration of `generateWranglerToml`, the `Resources` shape fix
  noted in #708's tracking comments, and the local `wrangler dev` runtime) is untouched.
  See [[dwk-workers-catalog-gaps]].
- **Every deploy now builds a `SiteGraphExplorerSnapshot`** (a filesystem walk plus
  `SiteContentGraph` lookups) when the graph is populated, adding real but non-hot-path cost to the
  main Deploy action. Not optimized further here — the design doc for #700 already accepts this
  cost as inherent to reusing `ImpactAnalysis` rather than building new usage-tracking
  infrastructure (§4 of the 700 design doc).
- **`provisionedWorkerResources` is per-site, not per-worker** — matching today's
  `WorkerComposition.ProvisionedResources` shape (one shared D1 database, one shared KV namespace,
  one shared R2 bucket across whichever features are active). If a future `@dwk/workers` catalog
  entry needs its own dedicated resource rather than the shared one, this shape needs revisiting —
  not needed for the 7 workers composed today.
- **Headless deploy (`SiteOperations.deploy`, App Intents/Shortcuts) has no `containerControl`
  parameter at all today**, and `DeployCommand`'s host-side executor is stubbed to fail explicitly
  after host-Node retirement — meaning that path likely can't execute a real deploy yet regardless
  of this issue. This design gives it the same effective-set computation for consistency (§8) but
  does not attempt to fix its container access; that's a pre-existing gap outside #709's scope.
- **`ContainerCommandRunner` is new production surface**, not just test plumbing — it's what makes
  `wrangler d1/kv/r2 create` and `wrangler d1 migrations apply` actually run inside the container
  for the first time. Scoped narrowly (mirrors `ContainerDeployExecutor`'s existing, reviewed
  pattern) to keep the risk contained.
