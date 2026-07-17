# Worker-name collision check at first deploy — design (#740)

- **Date:** 2026-07-16
- **Status:** Proposed
- **Issue:** [#740 — Worker-name collision: local slug uniqueness doesn't check the Cloudflare account's actual Workers](https://github.com/Anglesite/Anglesite-app/issues/740)
- **Related:** follow-up from [PR #739](https://github.com/Anglesite/Anglesite-app/pull/739) review, which made `SiteScaffolder` write a real `wrangler.toml` at scaffold time

## Problem

`SiteScaffolder` derives a Worker name from the site's display name (`SiteSlug.derive(from:)`,
[NewSiteDraft.swift:132-152](../../../Sources/AnglesiteCore/NewSiteDraft.swift)) and writes it into
`wrangler.toml` at scaffold time
([SiteScaffolder.swift:143-148](../../../Sources/AnglesiteCore/SiteScaffolder.swift)). Uniqueness is
checked only against the local recents registry (`SiteStore`, via the wizard's `slugTaken` closure,
[NewSiteWizardModel.swift:43-48](../../../Sources/AnglesiteCore/NewSiteWizardModel.swift)) — never
against the Cloudflare account's actual Worker names. `wrangler deploy` silently takes over any
existing Worker with a matching name rather than failing, so a collision is a silent deploy-time
takeover of an unrelated Worker, not an error surfaced to the user. Two scenarios reach this: a site
deleted locally and later re-scaffolded with the same slug, or two local installs sharing one
Cloudflare account scaffolding same-named sites independently.

## Decision

Check Worker-name availability against the live Cloudflare account, at first-deploy time (not
scaffold time), and block with a rename prompt on conflict — mirroring the existing
"surface failures, no override" pattern the pre-deploy security scan already uses
(`DeployCommand.Result.blocked`).

### Why first-deploy time, not scaffold time

`SiteScaffolder` is a deliberately offline, deterministic pipeline — no network access, no
Cloudflare token, by design (its own doc comment: "deterministic new-site pipeline... No Claude").
The wizard's `slugTaken` check is a synchronous, per-keystroke, `MainActor` closure over local
state — the wrong shape for a network call. `DeployCommand.deploy(...)` already resolves a live
Cloudflare API token before doing anything else
([DeployCommand.swift:90-98](../../../Sources/AnglesiteCore/DeployCommand.swift)), so it's the
first point in the pipeline with both a token and network access. The check runs there, as another
pre-spawn refusal alongside the existing token-missing check — before build, before the pre-deploy
scan, before wrangler.

### Cloudflare API addition

Add one read method, following the existing `CloudflareReading` shape
([CloudflareReading.swift](../../../Sources/AnglesiteCore/CloudflareReading.swift)):

```swift
public protocol CloudflareReading: Sendable {
    // ...existing methods...

    /// Every Worker script name (the `id` field) visible to the token's first account.
    /// Used to detect a Worker-name collision before a site's first deploy (#740).
    func workerScriptNames(apiToken: String) async throws -> [String]
}
```

`HTTPCloudflareClient`'s implementation mirrors the account-resolution pattern already used in
`CloudflareWebAnalyticsClient.webAnalyticsSites` ([CloudflareWebAnalyticsClient.swift:57](../../../Sources/AnglesiteCore/CloudflareWebAnalyticsClient.swift)):
resolve the first account id (`GET accounts?per_page=1`), then list scripts
(`GET accounts/{id}/workers/scripts`, paginated via the existing `paginated<T>` helper — the same
endpoint `CloudflareCapabilityProber` already probes for the `workers` permission scope, just read
for its full contents here instead of a bare success/failure check). Decode each entry's `id` field
(the script name).

### "First deploy" signal

`.site-config` gets a new unconditional marker, `CF_WORKER_DEPLOYED=true`, written via the existing
`SiteConfigFile.upsert` helper right where `DeployCommand` already persists `SITE_URL` on a
successful wrangler run ([DeployCommand.swift:197](../../../Sources/AnglesiteCore/DeployCommand.swift)).

This must be a **new, separate** marker rather than reusing `SITE_URL`'s absence: `persistSiteURL`
only writes `SITE_URL` when neither `DOMAIN` nor `SITE_DOMAIN` is already configured
([DeployCommand.swift:256-258](../../../Sources/AnglesiteCore/DeployCommand.swift)), and sites
scaffolded with `domainChoice == .transfer` already have `DOMAIN` set at scaffold time
([SiteScaffolder.swift:199](../../../Sources/AnglesiteCore/SiteScaffolder.swift)). For those sites,
`SITE_URL` would never be written on any deploy, so its absence does not mean "never deployed" — it
would falsely gate every single deploy of a custom-domain site into the collision check.
`CF_WORKER_DEPLOYED` is written on every successful wrangler run regardless of domain choice, so its
absence unambiguously means "this site has never deployed before."

The collision check fires when `.site-config` has no `CF_WORKER_DEPLOYED` marker. If
`.site-config` also has no `CF_PROJECT_NAME` (e.g. a pre-#701 site with a hand-edited
`wrangler.toml`), the check is skipped — fail open, since there's no reliable candidate name to
check, and this is no worse than today's behavior.

### `DeployCommand` changes

```swift
public actor DeployCommand {
    public enum Result: Sendable, Equatable {
        // ...existing cases...
        /// The candidate Worker name already exists on the connected Cloudflare account, and
        /// this site has never deployed before — refusing to silently take over someone else's
        /// (or a stale) Worker. Carries the taken name for the UI prompt.
        case workerNameConflict(name: String)
    }

    /// Returns the account's existing Worker script names for the given token. Production
    /// callers use `DeployCommand.defaultWorkerScriptNames` (`HTTPCloudflareClient`); tests
    /// inject a fake list.
    public typealias WorkerScriptNamesSource = @Sendable (_ apiToken: String) async throws -> [String]

    public init(
        tokenSource: @escaping TokenSource = DeployCommand.keychainTokenSource,
        workerScriptNamesSource: @escaping WorkerScriptNamesSource = DeployCommand.defaultWorkerScriptNames,
        executor: any DeployExecutor = HostDeployExecutor()
    ) { ... }
}
```

In `deploy(...)`, immediately after the existing token guard
([DeployCommand.swift:96-98](../../../Sources/AnglesiteCore/DeployCommand.swift)): read
`.site-config`; if `CF_WORKER_DEPLOYED` is absent and `CF_PROJECT_NAME` is present, call
`workerScriptNamesSource(token)` and check membership. A thrown error from the availability check
(network failure, `.unauthorized`, etc.) is non-fatal to the *check itself* — it's treated as "can't
confirm, proceed" (fail open) rather than blocking a deploy on a transient API hiccup; this mirrors
`CloudflareCapabilityProber`'s "a thrown transport error counts as missing — probes are advisory"
stance. A confirmed match returns `.workerNameConflict(name:)` before any build/preflight/wrangler
step runs.

### UX: rename sheet

`DeployModel` ([DeployModel.swift](../../../Sources/AnglesiteApp/DeployModel.swift)) handles
`.workerNameConflict` with a new sheet, in the same family as `CloudflareTokenPromptView` and the
`.blocked` preflight sheet: explains the name is already taken on the connected Cloudflare account,
and offers a text field (prefilled with a suggested `<slug>-2`) for a replacement name, validated
through `SiteSlug.derive`. On submit:

1. Replace just the `name = "..."` line in the existing `wrangler.toml` with the new slug — a
   targeted in-place string replace, not a full regenerate via `WorkerComposition.generateWranglerToml`.
   There is no existing reader that reconstructs a `[Feature]` list (or provisioned D1/KV resource
   IDs) from an already-written `wrangler.toml`, and the collision check can fire after a user has
   already run `SocialWorkerProvisionCommand` to opt into social features but before their first
   deploy — regenerating from scratch would silently drop that provisioned config. A single-line
   replace has no such risk.
2. Update `.site-config`'s `CF_PROJECT_NAME` via `SiteConfigFile.upsert` (already a replace-or-append
   helper — no new file-writing code needed).
3. Retry `deploy(...)`. The collision check re-runs against the new name (still no
   `CF_WORKER_DEPLOYED` marker) and loops back to the same sheet if the new name is also taken.

The user can also cancel out of the sheet with no changes made — deploy simply doesn't proceed.

### Testing

- `HTTPCloudflareClient.workerScriptNames` — unit tests for a populated list, an empty account,
  pagination across >100 scripts, and the unauthorized/http-error paths (mirroring existing
  `CloudflareReading` test patterns).
- `DeployCommand.deploy` gating — table of cases: no `CF_WORKER_DEPLOYED` + name taken →
  `.workerNameConflict`; no `CF_WORKER_DEPLOYED` + name free → proceeds to build; no
  `CF_WORKER_DEPLOYED` + no `CF_PROJECT_NAME` → proceeds (fail open); `CF_WORKER_DEPLOYED` present →
  always proceeds regardless of remote state (no regression on redeploys); `workerScriptNamesSource`
  throws → proceeds (fail open, non-fatal).
- `DeployCommand.deploy` success path — asserts `CF_WORKER_DEPLOYED=true` is written to
  `.site-config` alongside the existing `SITE_URL` persistence, including for a `.transfer`-domain
  site (where `SITE_URL` itself is *not* written, per the existing `persistSiteURL` guard).
- `DeployModel` — sheet presentation on `.workerNameConflict`, rename-and-retry flow (new name
  written to both `wrangler.toml` and `.site-config`, deploy retried), and the loop-back case where
  the retry also conflicts.

## Non-goals

- Any attempt to determine whether an existing remote Worker was created by *this* app install vs.
  a third party — the check only distinguishes "have I (this site, this install) ever successfully
  deployed" from "does a Worker with this name already exist," which is sufficient to cover both
  scenarios in the issue without needing Worker-side ownership metadata.
- Handling the case where a site's `Source/` repo is cloned to a second machine/install that hasn't
  deployed locally yet, but the Worker already exists from the first machine's deploy — this would
  surface as a (harmless, if slightly confusing) collision prompt on the second machine's first
  deploy attempt. Not addressed here; out of scope for this non-blocking follow-up.
- A dedicated "rename this site's Worker" entry point outside the conflict flow — the rename sheet
  only appears reactively, on a detected conflict.
- Auto-suffixing slugs (silently or otherwise) — rejected in favor of an explicit, blocking prompt,
  consistent with the existing pre-deploy-scan philosophy of surfacing failures rather than working
  around them.

## Target architecture invariants

- A site's Worker name is never silently reused from an unrelated existing Worker on first deploy.
- The collision check runs only on a site's first deploy (per-site, per-install) — redeploys never
  pay the extra API round-trip or risk a false positive from remote state that's actually the site's
  own prior deploy.
- A Cloudflare API failure during the collision check never blocks a deploy that would otherwise
  succeed (fail open) — the check is a safety net, not a hard dependency.
- `SiteScaffolder` remains fully offline; no Cloudflare coupling is added to the scaffold pipeline.
