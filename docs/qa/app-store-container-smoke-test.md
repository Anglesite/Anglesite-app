# App Store Container Runtime Smoke Test

**Issue:** [#81](https://github.com/Anglesite/Anglesite-app/issues/81)  
**Scope:** real-signed, write-heavy smoke for the single sandboxed `Anglesite` App Store target.  
**Target runtime:** `LocalContainerSiteRuntime` through Apple Containerization.

## Purpose

Validate the release-signing shape that CI cannot exercise:

- the App Store-sandboxed app carries the `com.apple.security.virtualization` entitlement;
- the app selects `LocalContainerSiteRuntime`, not any retired host Node preview path;
- preview, MCP/edit, image writes, build/preflight, deploy prompting, and teardown all work through the package security-scoped grant;
- sandbox denials and container failures are visible in logs.

This is an interactive author-run smoke. An ad-hoc build boots containers fine (the virtualization entitlement is unrestricted), but is not sufficient here — this smoke validates the *release signing shape* (Team ID, profile embedding, sandbox under a real identity), which only a real-signed build exercises.

## Preconditions

- Apple Silicon Mac on the supported macOS/Xcode versions.
- Apple Development or distribution signing identity for the app team.
- Standard Mac App Store (or Development) provisioning profile for the app id. No
  entitlement grant is involved — `com.apple.security.virtualization` is unrestricted.
- Container artifacts provisioned in the app bundle, or equivalent release artifact path:
  - `Resources/container-image/index.json`
  - `Resources/container-kernel/vmlinux`
  - `Resources/container-initfs/index.json`
- Cloudflare token available if the deploy step should reach a real `wrangler deploy`.

Run the local runtime probes first:

```sh
scripts/run-container-probe.sh echo
scripts/run-container-probe.sh boot
```

(The probe's default ad-hoc signing is sufficient — the entitlement needs no real identity.)

Make the #715 concurrent-vmnet regression gate deterministic instead of relying on ambient
machine state. Create and inspect a second shared-mode network, keep it alive during `boot`,
then remove it:

```sh
(
    set -e
    container system start
    container network create anglesite-715-regression
    trap 'container network delete anglesite-715-regression' EXIT
    container network inspect anglesite-715-regression
    scripts/run-container-probe.sh boot
)
```

The probe runtime log must show an allocated guest subnet that does not overlap the subnet in
the `container network inspect` output. The probe fixture has no lockfile, so reaching `BOOT:
PASS` also proves its in-guest `npm install` retained outbound DNS and HTTPS while the second
vmnet consumer was active. The subshell trap removes the regression network even when the probe
fails.

Both must pass, or the App Store smoke is expected to fail at runtime startup.

## Build Fixture And App

Use the helper script to create the site fixture and a real-signed app:

```sh
DEVELOPMENT_TEAM=<TEAMID> scripts/create-smoke-fixture.sh
```

The script prints the built app path and the interactive steps. Copy the built app to `~/Applications/` before launching; signed sandboxed apps should not be launched from temporary build directories.

## Smoke Matrix

| Case | Result | Evidence |
|---|---|---|
| Real-signed app launches from `~/Applications` |  |  |
| App signature has expected Team ID |  |  |
| App signature carries `com.apple.security.virtualization` |  |  |
| Imported fixture package opens with a security-scoped grant |  |  |
| Runtime selection logs `LocalContainerSiteRuntime` |  |  |
| No host Node preview fallback starts |  |  |
| Preview loads through loopback proxy |  |  |
| MCP/edit path applies a text edit through the in-container sidecar |  |  |
| Example photo highlights as an image drop target; dropping a Finder image writes optimized assets under `Source/public/images/` |  |  |
| Build/preflight/deploy path reaches the expected Cloudflare token or wrangler result |  |  |
| Foundation Models chat is present |  |  |
| GitHub `gh` settings/auth UI is absent in App Store build |  |  |
| Window close tears down VM/proxies |  |  |
| No relevant sandbox denials appear during the run |  |  |

Use `PASS`, `FAIL`, or `N/A`, and record exact failure logs for every non-pass.

## Log Capture

In a separate terminal, capture sandbox denials while running the smoke:

```sh
log stream --predicate 'eventMessage CONTAINS "deny"' --style compact
```

Also save the app debug pane logs for these sources when present:

- `runtime`
- `container:<siteID>`
- `deploy:<siteID>:build`
- `deploy:<siteID>:preflight`
- `deploy:<siteID>:wrangler`

## Acceptance

#81 can close when the matrix passes on a real-signed App Store-target build, or when every failure has a follow-up issue with captured logs and a clear owner.

## Re-run scope (2026-07-16)

The 2026-07-13/14 run (see #81 comments) executed the full matrix above on a
real-signed build and found one blocking failure plus six other bugs, all now
fixed and merged:

| Issue | Problem | Fixed by |
|---|---|---|
| #718 | Edit-overlay writes never reached host `Source/` — lost on next boot | #737 |
| #715 | Guest lost all outbound network when another vmnet consumer ran | #736 |
| #719 | Template `.gitignore` missed `node_modules`, etc. | #733 |
| #720 | Import didn't git-bootstrap plain (non-package) sites | #727 |
| #721 | Post-crash boot retry failed once (stale rootfs) | #729 |
| #722 | `create-smoke-fixture.sh` team-ID derivation + missing git init | #767 |
| #713 | `vendor-container-image.sh` broken since #698 | #730 |

None of this has been re-verified against a fresh build yet, and the
image-drop row was already inconclusive before these fixes landed. #81 stays
open until a re-run confirms the fixes hold and image-drop gets a human check.
This is a **focused re-run**, not a full matrix from scratch:

1. **Case 8 — MCP edit persistence (regression-critical).** Apply a text edit
   through the overlay, confirm the write lands in host `Source/`
   immediately (not just in-container), then close/reopen the window (or
   restart the app) and confirm the edit survived. This is the row #737 must
   fix; it's the reason #81 is still open.
2. **Image drop (still inconclusive).** Needs a literal human hand — drag a
   Finder image onto an `<img>` in the preview, confirm optimized assets land
   under `Source/public/images/`. No scripted/synthetic drag session
   substitutes for this (same tooling limit hit during the #491 run).
3. **Full wrangler round-trip.** #715 fixed the vmnet conflict that gated
   this in the first run — with it fixed, push a real `wrangler deploy`
   (needs a Cloudflare token in Keychain) instead of stopping at "reaches the
   expected token prompt."
4. **Spot-check, not full re-verification, of the other fixed rows:**
   - `create-smoke-fixture.sh` team-ID derivation (#722) — confirm the script
     picks the right identity/team with no manual correction.
   - Import → git-bootstrap (#720) — confirm a plain site import auto-inits
     without the earlier manual `git init` workaround.
   - `.gitignore` (#719) — confirm a freshly scaffolded site doesn't commit
     `node_modules`.
   - Boot retry after crash (#721) — low priority; only worth reproducing if
     a crash happens organically during the run.
   - `vendor-container-image.sh` (#713) — already proven working (it built
     the 07-13 image); just confirm the image still provisions cleanly since
     #730 landed.
5. **Everything that fully passed the first time** (sandbox/entitlement,
   runtime selection, chat presence, `gh` absence, teardown, log
   cleanliness) needs no re-execution — nothing on those paths changed since
   07-14.

### Execution blocker

This scoping pass was written from a session with no Xcode/macOS access, so
it cannot execute the matrix itself. The re-run needs the same preconditions
as the original: an Apple Silicon Mac, a real signing identity, and
hands-on GUI time — the image-drop case specifically cannot be automated.
