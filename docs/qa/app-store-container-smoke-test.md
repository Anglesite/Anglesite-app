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
