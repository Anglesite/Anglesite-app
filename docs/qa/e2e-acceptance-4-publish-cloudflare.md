# E2E Acceptance — Part 4: Publish to Cloudflare (no custom domain)

**Sequence:** Part 4 of 4 — requires Part 3's exit state (edited site, preview ready).
**Scope:** first deploy of the site to Cloudflare on the `*.workers.dev` subdomain only — the "Set this up later" domain path. Custom-domain attach, Harden, and Domain wizards are out of scope.

## ⚠️ Known blockers (must land before this part can pass)

Two app-side gaps mean a freshly scaffolded site **cannot currently complete this journey without manual intervention** (details in the [overview](e2e-acceptance-overview.md)):

1. **#701 — no wrangler config is materialized.** `Source/` ships only `worker/wrangler.toml.template` with `{{SITE_NAME}}` unsubstituted; the app runs bare `npx wrangler deploy`, which aborts without a config. Until fixed, testers must hand-write `Source/wrangler.toml` (copy the template, set a unique `name`) — record that workaround in evidence.
2. **#702 — `SITE_URL` is never written by the app deploy**, so the built site's canonical URLs/feeds carry `https://example.com` (case 8 documents the expected post-fix behavior).

## Purpose

Verify the deploy pipeline end-to-end: readiness gating, first-run Cloudflare token onboarding, build → pre-deploy scan → wrangler inside the container, the no-override blocked path, and a live `*.workers.dev` site surfaced in the deploy drawer.

## Preconditions

- Parts 1–3 passed on the same site; preview `.ready` (deploy runs **inside** the container — it is a hard dependency).
- A Cloudflare account the tester controls; **no** token in Keychain and no `CLOUDFLARE_API_TOKEN` in the environment (fresh-state reset).
- Network access from the guest.

## Acceptance Matrix

| # | Case | Result | Notes |
|---|---|---|---|
| 1 | Deploy affordance gating + tooltips |  |  |
| 2 | Token onboarding: happy path |  |  |
| 3 | Token onboarding: failure + cancel semantics |  |  |
| 4 | Deploy progress drawer |  |  |
| 5 | Blocked deploy: no override |  |  |
| 6 | Success: live workers.dev URL |  |  |
| 7 | Completion notification (quiet) |  |  |
| 8 | Published-site content sanity |  |  |
| 9 | Re-deploy idempotence |  |  |
| 10 | Negative: container stopped / wrangler failure |  |  |
| 11 | Second-site subdomain uniqueness |  |  |

## Test Cases

### 1. Deploy affordance gating + tooltips

- Toolbar **Deploy** (paperplane, prominent, paired with the health badge) and **Site ▸ Deploy** (⇧⌘D) are enabled only when: site valid, preview runtime ready, and no backup/audit in flight.
- Stop the dev server → Deploy disables with tooltip "Open the preview first to start the runtime before deploying". Restart it before continuing.
- The button is labeled **Deploy** (not Publish — "Publish" is the separate GitHub feature).

### 2. Token onboarding: happy path

Click Deploy with no stored token.

Expected:

- The deploy parks and the **"Connect to Cloudflare"** sheet appears: three numbered steps (link "Open Cloudflare API tokens" → pre-filled token page; the "Anglesite" custom token with "Edit Cloudflare Workers" fallback; create-and-paste), a secure paste field, **Cancel** / **Connect & deploy** (disabled while empty or verifying).
- Create the token in the dashboard, paste it, click **Connect & deploy**: spinner "Checking token…" → green **"Connected to <account>"** flash → sheet dismisses → **the parked deploy starts by itself** (no second Deploy click).
- The token is written to Keychain **only after** successful verification (check Keychain afterwards); it never appears in any log line.

### 3. Token onboarding: failure + cancel semantics

- Paste a mangled token → red failure message ("That token didn't work…" template guidance); sheet stays open; Keychain untouched.
- Empty/whitespace → "Paste your token first.", no verification attempt.
- (Simulate offline) → "Couldn't reach Cloudflare…" copy.
- **Cancel while a verification is in flight** → sheet closes, and no deploy may launch afterwards even if that verification later succeeds (the specifically-tested race). Re-clicking Deploy re-prompts.

### 4. Deploy progress drawer

On a running deploy, the slide-up drawer shows in order: **"Building site…"** → **"Running pre-deploy checks…"** → **"Deploying to production…"** → **"Finishing up…"**, with a live monospaced log tail (stderr in red, auto-scroll), a spinner header, and Dock-icon determinate progress. Deploy, Backup, and Audit remain mutually exclusive while running; double-clicking Deploy is a no-op.

### 5. Blocked deploy: no override

Seed a violation — e.g. paste a real-looking email address into page copy (PII scan) — and deploy.

Expected:

- The pipeline stops after the scan; **wrangler never runs**.
- The blocked sheet lists categorized findings (e.g. "PII — email address") with file + remediation, and offers **only "Got it"** — there is no bypass/override control anywhere (hard product rule).
- Remove the violation, redeploy → scan passes. Non-blocking warnings (e.g. OG-image absence) appear in the warnings section without stopping the deploy.

### 6. Success: live workers.dev URL

Expected on completion:

- Drawer header becomes the deployed URL — shape `https://<name>.<account>.workers.dev` — subtitle "deployed in N.N s", with **Copy URL**, a ShareLink, and **Open in browser** (opens the default browser at the live site).
- The drawer **never auto-dismisses**; it closes only via **Dismiss**.
- Edge case to note: if wrangler exits 0 but the URL can't be parsed, the app reports "wrangler exited cleanly but no deployed URL was found in its output" — a deploy may be live despite this error (parser fragility, see overview).

### 7. Completion notification (quiet)

A deploy-finished notice arrives **provisionally** in Notification Center — no permission dialog is ever raised. Honors the General "Notify when site operations finish" toggle.

### 8. Published-site content sanity

Visit the live URL in a browser:

- Homepage shows the Part 3 edits (headline, image); `/about` and `/blog/` (with the Part 3 post) render; `/rss.xml` serves.
- No dev-only surfaces: `/keystatic` must not exist in production output.
- Canonical URLs / feed self-links reference the deployed host — **currently expected to show `https://example.com`** until the `SITE_URL` blocker lands; record actual values.
- The health badge reflects the passed scan ("Ready to deploy" green after a recheck).

### 9. Re-deploy idempotence

Make a small visible edit (Part 3, case 3 style), deploy again.

Expected: no token prompt (Keychain hit); same URL; the edit is live after completion; drawer state from the prior run (logs, milestone) fully resets.

### 10. Negative: container stopped / wrangler failure

- Stop the dev server and attempt Site ▸ Deploy: it must refuse/disable rather than attempt a host-side deploy ("Container isn't running — open/start the site's preview first." if it reaches exec). There is **no host fallback** (host Node is retired).
- Force a wrangler failure (e.g. revoke the token in the Cloudflare dashboard, then deploy): drawer shows "Deploy failed" + reason, red stderr lines, a **Copy log** button, and the on-device AI failure summary labeled "AI summary — verify against the log below" (summary is device-gated; its absence on non-AI hardware is not a fail).

### 11. Second-site subdomain uniqueness

Create a second site (Part 2 abbreviated) and deploy it.

Expected: it must land on a **different** workers.dev subdomain than "QA Bakery" — not overwrite it. With the current placeholder/template gap, two sites sharing a hand-copied config name **will** clobber each other; this case is the acceptance test for the wrangler-config fix (per-site unique `name`).

## Run closeout

- File the evidence (matrix, timings, URL, screenshots) on the tracking issue for this run, #706.
- On full PASS: close #586, #491, and #656 with links to the Part 3 evidence; report Part 4 results on #701 and #702.
