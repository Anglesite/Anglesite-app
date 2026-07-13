# End-to-End QA Acceptance Run — Overview

**Tracking issue:** [#706](https://github.com/Anglesite/Anglesite-app/issues/706) — record all evidence there.
**Scope:** the core owner journey, first launch through first publish, as four sequential parts:

| Part | Doc | Journey |
|---|---|---|
| 1 | [e2e-acceptance-1-initial-launch.md](e2e-acceptance-1-initial-launch.md) | Initial launch (fresh install, no prior state) |
| 2 | [e2e-acceptance-2-new-website.md](e2e-acceptance-2-new-website.md) | Create a new website |
| 3 | [e2e-acceptance-3-basic-edits.md](e2e-acceptance-3-basic-edits.md) | Basic edits on the website |
| 4 | [e2e-acceptance-4-publish-cloudflare.md](e2e-acceptance-4-publish-cloudflare.md) | Publish to Cloudflare (no custom domain) |

**Target:** the `Anglesite` scheme (single sandboxed Mac App Store target). Run the parts **in order on the same machine and the same site** — each part's exit state is the next part's precondition.

## Shared preconditions

- Apple Silicon Mac, macOS 26+ (macOS 27+ for the Siri AI probes to report green).
- Xcode 27+ / Swift 6.4 toolchain; `xcodegen generate` run in the checkout.
- Container boot artifacts provisioned (`scripts/vendor-container-image.sh` with `ANGLESITE_PLUGIN_SRC` set, plus `scripts/vendor-container-kernel.sh`) — see [local-container-runtime-smoke-test.md](local-container-runtime-smoke-test.md) §Artifact Provisioning. A checkout without them fails every preview by design (`UnavailableSiteRuntime`).
- `scripts/copy-plugin.sh` run so `Resources/plugin/` is populated.
- A build signed with `Resources/Anglesite.entitlements` (ad-hoc Debug is fine — the virtualization entitlement is unrestricted).
- Network access (guest `npm install`, wrangler).
- For Part 4: a Cloudflare account the tester controls, with no pre-existing token in Keychain or `CLOUDFLARE_API_TOKEN` in the environment.

## Fresh-state reset (before Part 1)

1. Quit Anglesite.
2. Delete the app container: `~/Library/Containers/io.dwk.anglesite/` (sandboxed builds keep Application Support, preferences, and `recents.json` there). For non-container state, also check `~/Library/Application Support/Anglesite/`.
3. Remove the Cloudflare token from Keychain (Keychain Access → search "Anglesite" / "Cloudflare") and ensure `CLOUDFLARE_API_TOKEN` is not exported in the launch environment.
4. Move aside any existing `~/Sites/*.anglesite` packages (or use a Sites-root override pointed at an empty directory).

## Evidence to record

For each part: commit SHA + build config, macOS/Xcode versions, PASS/FAIL per matrix row, wall-clock timings where a case asks for them, and screenshots of any FAIL plus the Debug-pane log excerpt.

## Issue map

### Blockers — must land before the full run can pass

- **#701 — scaffolded sites have no deployable wrangler config.** The template ships only `Resources/Template/worker/wrangler.toml.template` with an unsubstituted `{{SITE_NAME}}` placeholder; neither `SiteScaffolder` nor the deploy pipeline renders it to `wrangler.toml`, `.site-config` gets no `CF_PROJECT_NAME`, and `DeployCommand` runs bare `npx wrangler deploy` — which aborts with no config. The plugin deploy SKILL (the retiring `claude --print` path, epic #459) is the only thing that ever wrote a Worker name, and it edits a `wrangler.jsonc` the template doesn't ship. Deterministic fix belongs in the scaffold (render the template with a slugified, uniquified site name) per the #459 "tool before brain" direction. Blocks Part 4 entirely.
- **#702 — app deploy never writes `SITE_URL`.** `astro.config.ts` reads `SITE_URL` from `.site-config` ("the deploy step writes the real domain… before build" — only the plugin skill did). On the no-custom-domain path the app should set it to the workers.dev URL (first deploy: after URL discovery; or derive from the Worker name pre-build). Until then, canonical URLs/feeds on a published site carry `https://example.com`. Blocks Part 4 case 8.

### Open issues this run verifies (closable on PASS with evidence)

- **#586** — navigator content commands manual GUI verification → Part 3, cases 6–9.
- **#491** — Component Editor slice-1 manual GUI smoke → Part 3, case 10.
- **#656** — MAS-sandboxed GUI smoke of SwiftGit2 content ops (#649) → Part 3 run on a sandboxed build (this target is sandboxed, so the same pass counts; record git evidence).

### Open issues adjacent, not required

- **#81 / #617** — the real-signed App Store variant of this run and Phase 10.1 closeout; this run on ad-hoc Debug signing is the rehearsal.
- **#616** — distribution-grade pinned container artifacts; dev vendoring suffices for this run.
- **#679 / #680** — keyboard-only pass and Mac-assed polish audit; overlap Part 1/3 surfaces but have their own checklists.
- **#654 / #655** — GitHub publish / backup transport under sandbox: out of scope (Part 3 notes Backup is excluded from the minimal loop).

### Smaller gaps observed while authoring (filed)

- **#703** — wizard "Set this up later" copy and analytics-host fallbacks say **`<slug>.pages.dev`** (`NewSiteWizardModel.swift:51`, `PlistEditorModel.swift:286`) but the deploy target is **Workers → `*.workers.dev`**.
- **#704** — `DeployCommand.extractDeployedURL` anchors on wrangler's `Published` output line; a wrangler output-format change turns a successful deploy into "wrangler exited cleanly but no deployed URL was found".
- **#705** — `ComponentEditorView` header comment still says "Read-only (slice 1)" though slice-2 style writes shipped.
- No `representedURL`/proxy-icon wiring was found on the site window; verify in Part 2 case 9 and fold into #680 if missing (noted on #680).
