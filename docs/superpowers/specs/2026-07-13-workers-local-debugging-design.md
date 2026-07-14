# Running Workers locally for debugging — design

**Issue:** [#700](https://github.com/Anglesite/Anglesite-app/issues/700) (becomes a tracking epic)
**Date:** 2026-07-13
**Status:** Proposed

## 1. Problem

A site's Cloudflare Worker composes `@dwk/workers` packages (webmention, indieauth, micropub,
websub, activitypub, microsub, webfinger today; more — including packages not yet named in this
codebase, e.g. the issue's ESI/Solid-Pod/WebDav examples — as `@dwk/workers` grows) behind the
site's static assets. Today the only way to see a Worker run is a real Cloudflare deploy. There is
no local dev/debug path, no per-site record of which workers are active, and no UI for turning
them on or off. The result: every Worker iteration costs a deploy, and there's no visibility into
which workers a site is actually running or why.

## 2. Scope

This spec covers three implementation slices, each independently shippable as a paired PR against
`Anglesite/anglesite` (where `@dwk/workers` publishes its manifest) where needed:

- **700a — Worker catalog + local runtime.** Fetch the `@dwk/workers` catalog; run a local
  `wrangler dev` session alongside the existing Astro dev server inside `LocalContainerSiteRuntime`.
- **700b — Persisted worker state + deploy integration.** Per-site active-worker state; generate
  `wrangler.toml` from the effective active set; remove workers from Cloudflare when deactivated.
- **700c — Site Settings: Workers tab.** A new tab in the existing per-site settings surface
  (`PlistEditorView`) showing every catalog worker, grouped, with component-tied workers shown
  read-only and settings-activated workers toggleable.

**Deferred, not in this spec:** a "Webserver" menu-bar menu with per-open-site submenus and
Cloudflare dashboard deep-links (the issue's fourth bullet). Cut from scope during design review —
worth revisiting once 700a–c ship and it's clear what other affordances people actually reach for.
File as a follow-on issue against #700 if picked up later; do not build it as part of this work.

**Out of scope entirely:** anything about *which* packages `@dwk/workers` ships (ESI, Solid-Pod,
WebDav, or otherwise) — that's the monorepo's decision, not this app's. This design treats the
catalog as opaque data (§3).

## 3. Worker catalog

`@dwk/workers` publishes `catalog.json` at the monorepo root, alongside the existing
`conformance/status.json` that `WorkersConformanceReader` (`Sources/AnglesiteCore/WorkersConformance.swift`)
already knows how to parse — same publishing channel, new file. Shape:

```json
{
  "workers": [
    {
      "id": "webmention",
      "displayName": "Webmentions",
      "description": "Receive and verify webmentions for posts",
      "group": "social",
      "binding": { "kind": "componentTied", "componentIDs": ["webmention-form"] },
      "resources": { "needsD1": true, "needsKV": true, "needsR2": false }
    },
    {
      "id": "solid-pod",
      "displayName": "Solid Pod",
      "description": "Expose a Solid-compatible personal data store for this site",
      "group": "storage",
      "binding": { "kind": "settingsActivated" },
      "resources": { "needsD1": false, "needsKV": true, "needsR2": true }
    }
  ]
}
```

- `binding.kind` is either `componentTied` (active iff a bound component is used on ≥1 page —
  never manually toggled, §5) or `settingsActivated` (manually toggled in the Workers tab, §5).
  `componentIDs` are Site Graph Explorer node IDs (§4).
- `group` is a free-text grouping key the Workers tab sections by (`social`, `storage`, whatever
  the manifest declares) — never hardcoded in Swift, per the decision to keep the app's catalog
  model generic rather than enumerate specific worker names.
- `resources` generalizes `WorkerComposition.Feature`'s existing `needsD1`/`needsKV`/`needsR2`
  flags (`Sources/AnglesiteCore/WorkerComposition.swift:28-53`) from a closed, hand-maintained
  Swift enum to manifest-driven data.

**New type:** `Sources/AnglesiteCore/WorkerCatalog.swift` — `WorkerDescriptor` (Codable struct
matching the shape above) plus `WorkerCatalogReader.parse(_:) -> [WorkerDescriptor]`, mirroring
`WorkersConformanceReader`'s stateless-parser shape. Unlike `WorkersConformanceReader` — which has
no fetch/cache call site anywhere in the codebase today, only the parser — `WorkerCatalog` needs an
actual fetch-and-cache layer (this is genuinely new infrastructure, not an extension of existing
plumbing): fetch on Workers-tab open and at deploy time, cache the last-known-good catalog to disk,
and degrade to the cached (or empty) catalog — never a crash or a blocked UI — if the network fetch
fails. `WorkersConformance` could adopt the same fetch/cache layer later; not required for this work.

**Existing code that changes shape:** `WorkerComposition.Feature` (`WorkerComposition.swift:12-54`)
is today a closed `CaseIterable` enum hardcoding exactly the seven V-2..V-4 package names, with
`needsD1`/`needsKV`/`needsR2` as switch statements over those cases. `generateWranglerToml` needs
to accept `[WorkerDescriptor]` (or an equivalent id+resources value) instead of `[Feature]`, since
manifest-driven workers (Solid-Pod, WebDav, whatever ships later) won't have enum cases. The
existing `Feature.v2`/`.v3`/`.v4` phase lists and `WorkersConformanceStatus.phaseRequirements`
(`WorkersConformance.swift:47-51`) keep working by mapping npm package name → catalog `id` rather
than enum case — phase-gating logic is unchanged, only its input type is.

## 4. Component-tied workers reuse Site Graph Explorer

"Which pages use component X" is already a solved, queryable problem — no new tracking needed.
`ImpactAnalysis.analyze(snapshot:targetID:)` (`Sources/AnglesiteCore/ImpactAnalysis.swift`) walks
the reverse transitive closure of the Site Graph Explorer's dependency graph
(`Sources/AnglesiteCore/SiteGraphExplorer.swift`, which already models `component` as a distinct
node kind) and returns `report.affectedPages`. For each `componentTied` worker, the Workers tab
runs `ImpactAnalysis.analyze` against the worker's `componentIDs` and shows the resulting page list
directly — no new usage-tracking infrastructure, just a new caller of an existing API.

## 5. Persisted state (700b)

Extend `SiteSettings` (`Sources/AnglesiteCore/SiteConfigStore.swift:12-30`), preserving the file's
hard rule that every field is `Optional` for forward-compat decoding:

```swift
/// Worker catalog IDs the user has manually toggled on (settingsActivated workers only).
/// Component-tied workers are never stored here — their active state is always recomputed
/// live from Site Graph Explorer / ImpactAnalysis (§4), so it can't drift from site content.
public var activeWorkerIDs: [String]?

/// The full effective active set (component-tied + settings-activated) as of the last
/// successful deploy — the diff baseline for removing deactivated workers (§6).
public var lastDeployedWorkerIDs: [String]?
```

**Effective active set** (computed, never stored as its own field):
`{ componentTied workers with ≥1 ImpactAnalysis-affected page } ∪ { activeWorkerIDs }`.

## 6. Deploy integration (700b)

At deploy time, `WorkerComposition` computes the effective active set (§5) and generates
`wrangler.toml` from it (generalizing `generateWranglerToml` per §3). Before deploying, it diffs
the effective set against `lastDeployedWorkerIDs`: any worker present in the old set but absent
from the new one gets an explicit Cloudflare-side removal (route/binding teardown) ahead of the new
deploy — deactivating a worker is a real security/cost action, not just an omission from the next
bundle, per the issue's "respecting security, performance, cost" framing. After a successful
deploy, `lastDeployedWorkerIDs` is updated to the new effective set.

`lastDeployedWorkerIDs` lives in `Config/` (app-owned, never git) rather than being inferred from
`Source/`'s current `wrangler.toml`, because `Source/` is a git repo — a teammate's pull or a
hand-edit could change `wrangler.toml` between app sessions. The diff baseline must reflect what
the app actually told Cloudflare last, not whatever a file currently says.

## 7. Local runtime (700a)

`LocalContainerSiteRuntime` (`Sources/AnglesiteCore/LocalContainerSiteRuntime.swift`) gains a
second guest process, sibling to the existing `astro dev` + MCP sidecar (`container/start-dev-server.sh`):
`wrangler dev --local` (Miniflare-backed local emulation — **no calls to the user's real Cloudflare
account**; KV/D1/R2 are locally persisted, matching wrangler's own default local mode). This keeps
a debug session from touching production data or incurring cost, and means it works without the
Cloudflare token having been onboarded at all.

- **Started on demand**, not unconditionally: only when the site's effective active set (§5) is
  non-empty. A site with no active workers pays no extra container cost.
- **New vsock-proxied port** carries the worker's local URL, exposed alongside the existing
  `previewURL`/`mcpURL` on the runtime's session/state payload — extending `SiteRuntimeState`
  rather than changing the `SiteRuntime` protocol's shape (`start`/`observe`/`mcpClient` stay as
  they are; see the architecture note below).
- **Logs stream into the existing debug pane** via the same `LogCenter` path other container
  subprocesses already use — no `/dev/null`, consistent with "logs are sacred."
- **Toggling a worker in the Workers tab** (§8) while a local session is running restarts the local
  `wrangler dev` process with the new active set, so the debug session reflects the change
  immediately without a full container reboot. Production deploy is unaffected until the next
  explicit deploy (§6).
- **Process isolation:** a `wrangler dev` crash must not take down the Astro session. The
  container's process supervisor needs independent restart/health tracking per child process
  (Astro, MCP sidecar, wrangler dev), not just a single "container is up" signal.

`SiteRuntime`'s minimal contract (one `start`, one `observe` state stream, one `mcpClient`) is what
makes this additive rather than a breaking change to all three conformers (`LocalContainerSiteRuntime`,
`RemoteSandboxSiteRuntime`, `UnavailableSiteRuntime`) — the protocol only ever exposed a state
stream and an MCP client, never raw ports or process handles, so a second live process is a change
to the *state payload*, not the protocol surface. `RemoteSandboxSiteRuntime` and
`UnavailableSiteRuntime` are unaffected by this slice — the local Workers dev server is a
local-container-only capability for V1 (remote-sandbox parity, if wanted, is future work).

## 8. Site Settings: Workers tab (700c)

**Tab mechanism:** add `.workers` to `PlistEditorView`'s existing `SettingsTab` enum (alongside
`.website`/`.analytics`/`.redirects`, `Sources/AnglesiteApp/PlistEditorView.swift`) — reuses the
segmented `Picker` already there. `PlistEditorModel` becomes the first UI consumer of
`SiteConfigStore` beyond the existing `displayName`-override path: on tab select it loads
`SiteSettings`, fetches/reads the cached `WorkerCatalog`, and runs `ImpactAnalysis` for each
component-tied worker.

**Layout**, grouped by the catalog's `group` field:

```
┌─ Workers ──────────────────────────────────────────────┐
│ [Production Logs]  [Analytics]   ← disabled until       │
│                                     lastDeployedWorkerIDs≠[] │
│                                                           │
│ ▼ Social                                                 │
│   Webmentions          Active — used on 3 pages →       │  read-only, component-tied
│   IndieAuth            Inactive — not used               │
│                                                           │
│ ▼ Storage                                                │
│   Solid Pod            [off ⇄]                            │  toggle, settings-activated
│   WebDav               [on  ⇄]                            │
└────────────────────────────────────────────────────────────┘
```

- Component-tied rows are **read-only** — never a manual toggle. "Active — used on N pages" links
  to the `ImpactAnalysis` result (exact interaction — popover vs. Navigator selection — is an
  implementation-time UI call, not a design fork).
- Settings-activated rows get a toggle bound to `activeWorkerIDs` membership; flipping it writes
  `SiteSettings` immediately via `SiteConfigStore.save` and triggers the local-runtime restart
  described in §7.
- The top-of-pane Logs/Analytics buttons are `NSWorkspace.shared.open()` deep-links into the
  Cloudflare dashboard (no in-app API wrapper exists for Cloudflare Logs/Analytics, and building
  one is out of scope here) — disabled until `lastDeployedWorkerIDs` is non-empty, i.e. after the
  site's first deploy that included at least one worker.

## 9. Testing

- `WorkerCatalogReader.parse` — unit tests over fixture JSON (valid, missing optional fields,
  malformed → graceful empty result), mirroring `WorkersConformanceReader`'s existing test shape.
- `WorkerComposition.generateWranglerToml` — existing tests migrate from `[Feature]` fixtures to
  `[WorkerDescriptor]` fixtures; add cases for a manifest-only worker with no historical `Feature`
  case, to prove the generalization didn't silently drop coverage.
- `SiteConfigStore` — round-trip test for the two new fields, plus a decode test with an
  old-format `settings.plist` (missing the new keys) to confirm forward-compat still holds.
- Deploy diff/removal logic — unit test the diff computation (old set vs. new effective set →
  removal list) independent of actual Cloudflare API calls.
- `LocalContainerSiteRuntime`'s new process — covered by the existing `ANGLESITE_CONTAINER_TESTS=1`
  / `ANGLESITE_CONTAINER_E2E=1` opt-in suites (per CLAUDE.md, `swift test` alone can't boot VMs);
  add a case that toggles a worker on and asserts the local worker URL becomes reachable.
- Workers tab — `PlistEditorModel` unit tests for load/toggle/save; a manual GUI smoke pass
  (per this repo's pattern of owed manual-smoke follow-ups on new UI, e.g. #491) rather than a new
  hosted-app UI test, consistent with how other `PlistEditorView` tabs are covered today.

## 10. Open questions / risks

- **`@dwk/workers` catalog.json doesn't exist yet** — this spec assumes the monorepo will publish
  it; 700a is blocked on that landing, the same way V-2..V-4 are blocked on conformance status
  today. Coordinate as a paired-repo change per this repo's existing cross-repo convention.
  Worth confirming with the monorepo maintainer (same author) before implementation starts.
  `@dwk/workers` is pre-1.0 (0.1.0-beta.2), so treat catalog.json's shape as provisional until
  the monorepo stabilizes it.
- **Cloudflare dashboard URL scheme** for the Logs/Analytics deep-links (§8) needs confirming
  against Cloudflare's actual current dashboard paths at implementation time — a lookup detail,
  not a design fork, but worth verifying before 700c ships rather than assuming.
- **`WorkerComposition.Feature` → `WorkerDescriptor` migration** touches existing, working V-2..V-4
  gating code (`SocialWorkerProvisionCommand.swift`, `SocialPublishPlan.swift`, both only skimmed
  during research) — 700b's implementer should read those fully before changing `Feature`'s shape,
  to avoid silently breaking the social-phase rollout this design doesn't otherwise touch.
- **Newsletter integration's bespoke Worker** (`Resources/Template/integrations/worker/subscribe-worker.js`,
  from the Integration wizard framework, #462) is a second, independent per-site Worker deployment
  path that predates and doesn't go through `@dwk/workers`/`WorkerComposition` at all. This spec
  doesn't reconcile it — it's a pre-existing inconsistency, not one this work introduces — but a
  future pass should decide whether newsletter's worker ever moves onto this catalog model.
