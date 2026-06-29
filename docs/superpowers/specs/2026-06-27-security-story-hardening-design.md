# Security story hardening — design (#402)

**Date:** 2026-06-27
**Epic:** [#402](https://github.com/Anglesite/Anglesite-app/issues/402) — Security story hardening (tracking)
**Sub-issues:** [#403](https://github.com/Anglesite/Anglesite-app/issues/403) (A), [#404](https://github.com/Anglesite/Anglesite-app/issues/404) (B), [#405](https://github.com/Anglesite/Anglesite-app/issues/405) (C1), [#406](https://github.com/Anglesite/Anglesite-app/issues/406) (C2), [#407](https://github.com/Anglesite/Anglesite-app/issues/407) (C3), [#408](https://github.com/Anglesite/Anglesite-app/issues/408) (C4)
**Scope:** template (`Resources/Template/`) for layers A/B/C1; `AnglesiteCore` + app for C2/C3; C3 may be `cross-repo` (paired plugin PR)

## Problem

A community Cloudflare config we evaluated ([buybitart/cloudflare-security-art](https://github.com/buybitart/cloudflare-security-art))
prompted a review of Anglesite's security posture. The generated-site baseline already beats
that guide — build-time CSP from `.site-config` (`scripts/csp.ts`), a modern `public/_headers`,
and a `pre-deploy-check.ts` that validates the CSP and scans for leaked secrets.

The gaps are elsewhere:

- A few **response headers** current OWASP/Mozilla guidance recommends are missing (HSTS,
  COOP/CORP, `upgrade-insecure-requests`).
- The **pre-deploy check** doesn't cover SRI, mixed content, or unsafe external links.
- The **Cloudflare edge/account/DNS layer is not addressed at all** — DNSSEC, CAA, email
  authentication, Bot Fight Mode. This is the largest gap and the highest-leverage one for
  our audience.

## Threat model (scoped)

Anglesite hosts **static** marketing/portfolio/creator/small-business sites on Cloudflare
Pages — no server, no database, no app backend. That narrows what matters.

**High-likelihood threats:** secret/credential leakage committed to the repo; deploy-token
compromise → defacement; **dangling DNS / subdomain takeover**; **email spoofing** (phishing
in the owner's name from an unprotected domain); TLS cert mis-issuance; clickjacking; mixed
content; supply chain via third-party embeds.

**Low value for this audience:** elaborate WAF rule-writing and rate limiting. There is no
dynamic attack surface, and Cloudflare's auto-on Free Managed Ruleset already absorbs DDoS.
This is why we prioritize **DNS + email + headers** over WAF gymnastics — and why the linked
guide's "2 requests / 10s" rate limit is both broken (blocks normal visitors) and unavailable
(rate-limiting rules are effectively a paid feature).

## Cloudflare free-plan reality

The delivery model must respect what's actually available to a free-plan user:

- ✅ free / zero-config: DDoS L3–7, Free Managed Ruleset (auto-on), Bot Fight Mode (toggle),
  Always-Use-HTTPS, DNSSEC, CAA, all email-auth DNS records.
- ⚠️ **5 custom WAF rules** maximum on free.
- ❌ rate-limiting rules — effectively paid.

## Decisions

Settled during brainstorming:

1. **Holistic scope across four layers** (A: headers, B: pre-deploy checks, C: edge/account/DNS,
   D: supply chain), decomposed into per-layer sub-issues rather than one monolithic change.

2. **Hybrid delivery model.** Anglesite auto-applies only **repo-owned artifacts** (the
   headers/CSP it already generates, plus `security.txt`/`robots.txt`). Account/edge/DNS
   changes are **opt-in**: a "Harden" action computes a change plan, previews an **exact diff**,
   and applies only on explicit consent, then re-runs the audit. Never silent — it surfaces
   failures rather than overriding, consistent with `pre-deploy-check`. A standing **read-only
   Security audit** reports a graded scorecard and drift.

3. **AI-crawler blocking is opt-in, off by default.** Blocking `gptbot`/`claudebot`/etc. trades
   away AI-search discoverability — a real cost for creator/business sites — and is
   philosophically odd to default-on in a Claude-powered app.

4. **Config split.** Repo-artifact prefs (`HSTS_PRELOAD`, `SECURITY_CONTACT`, `BLOCK_AI`, …) live
   in `.site-config` (`Source/`, template-owned). The Cloudflare API token and edge prefs live
   in `Config/` (app-owned, never git). Token scope is minimal and documented.

## Layers

### A — Response headers / CSP (#403)

Extend `scripts/csp.ts` `buildHeaders()`. Add to the generated `public/_headers`:

- `Strict-Transport-Security: max-age=31536000; includeSubDomains`
- `preload` directive **behind opt-in `.site-config` `HSTS_PRELOAD`** — hard to reverse, never default-on
- `Cross-Origin-Opener-Policy: same-origin-allow-popups` — *not* bare `same-origin`, which severs
  `window.opener` for popups the site itself opens (OAuth sign-in, Stripe/PayPal checkout — common
  for this audience); `-allow-popups` keeps those working while still isolating attacker-opened windows.
- `Cross-Origin-Resource-Policy: same-site` — *not* `same-origin`, so same-site subdomains can still
  load shared assets (e.g. a logo on `blog.example.com`); cross-*site* isolation is retained.
- `upgrade-insecure-requests` in the CSP

Already shipped as always-on defaults (predating this work, no tradeoff for static sites; keep them):
`X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`,
`Referrer-Policy: strict-origin-when-cross-origin`, and the locked-down `Permissions-Policy`.

Explicitly **not** doing: `X-XSS-Protection` stays absent (deprecated/harmful); COEP stays off
by default (breaks embeds), opt-in only. Stretch (phase 2): nonce/hash inline scripts to drop
inline-script trust; `'unsafe-inline'` on `style-src` remains an accepted tradeoff for now.

### B — Pre-deploy checks (#404)

Extend `scripts/pre-deploy-check.ts` (keep CSP validation + secret scanning), reusing the
`Issue { severity, message, file }` model. Add: SRI on external `<script>`/`<link>` (warn —
including a separate warning for `integrity` present but `crossorigin` missing, which fails CORS),
mixed-content scan (**warn** — advisory; layer A's `upgrade-insecure-requests` auto-upgrades these
at runtime, so it does not block deploy), `target="_blank"` without `rel="noopener"` or
`rel="noreferrer"` (warn; `noreferrer` implies `noopener`), presence of `.well-known/security.txt`
and `robots.txt` (warn), and a dependency/lockfile vuln surface (warn — deferred to a follow-up).

### C1 — Repo-owned edge artifacts (#405)

Generate, mirroring the `csp.ts` pattern (pure function + writer + tests):

- `public/.well-known/security.txt` — `Contact:` + `Expires:` (RFC 9116), from `SECURITY_CONTACT`.
  **`Expires` is regenerated with a fresh future date (+1 year) on every build/deploy** (the same
  pipeline that runs `csp.ts`), so it never silently lapses — no user action and no warning path needed.
- `public/robots.txt` — allow legitimate crawlers; AI-crawler directives gated behind C4

### C2 — `CloudflareClient` seam + read-only audit (#406)

- **`CloudflareClient`** (AnglesiteCore) — protocol abstracting the Cloudflare API; mockable in
  tests; centralizes MAS sandbox/token handling. Token in Keychain (existing `area:secrets`
  pattern). Token scope: **read** (Zone Read, DNS Read, Zone Settings Read) for audit;
  **write** (Zone DNS Edit, Zone Settings Edit, WAF Edit) for the C3 Harden action.
  Read methods: DNSSEC status, CAA, SSL/Always-HTTPS/HSTS edge settings, MX/SPF/DMARC, Bot
  Fight Mode, custom-rule list.
- **`SecurityAudit`** (pure, testable) — input: built `dist/` + account-state snapshot → graded
  findings (mirror the pre-deploy `Issue` model). Surfaced as a scorecard in the debug/Settings
  panel; reports drift; never auto-fixes.

Keep app-target logic thin; push testable logic into `AnglesiteCore` so it runs under
`swift test` on CI (hosted app tests don't run there).

### C3 — Opt-in "Harden Cloudflare" action (#407)

Compute a change plan → preview exact diff → apply on consent → re-run the C2 audit.
Dry-runnable, never silent. Changes (all preview-gated):

- Enable **DNSSEC**
- Add **CAA** records authorizing **all CAs Cloudflare's free plan can rotate between** — Let's Encrypt
  (`letsencrypt.org`), DigiCert (`digicert.com`), and Google Trust Services (`pki.goog`) — or, more
  precisely, read the zone's current issuer via the SSL API (`GET /zones/{id}/ssl/certificate_packs`)
  and authorize that plus `letsencrypt.org` as fallback. **Pinning a single CA breaks cert renewal
  silently on the next rotation**, so the rule template must enumerate all three by default.
- **Always-Use-HTTPS** + edge **HSTS**
- **Bot Fight Mode** on
- For non-mail domains: **null-MX + `SPF -all` + `DMARC p=reject`** (detect mail-sending first)
- Up to **5 curated WAF custom rules** — only durable parts: block `.env`/`.git`/dotfile paths,
  path traversal, obvious SQLi/XSS query-string patterns. **The dotfile rule must carve out
  `/.well-known/`** (negative match `starts_with(http.request.uri.path, "/.well-known/")` *before*
  the dotfile block) so it never blocks `/.well-known/security.txt` (C1) or
  `/.well-known/acme-challenge/` (Cloudflare-managed cert issuance).

Explicitly **not** included: the 2-req/10s rate limit; blanket `curl`/`wget`/`python-requests`
blocking (breaks monitors, webhooks, RSS); outdated-browser sniffing / referrer challenges.

Needs `CloudflareClient` **write** scope (Zone DNS edit, Zone settings edit, WAF edit) — bump
the documented token scope. If any of this routes through the plugin MCP server, it lands as a
paired plugin + app PR (`cross-repo`).

### C4 — Optional AI-crawler toggle (#408)

Off by default. `.site-config` `BLOCK_AI` → `robots.txt` directives, optional edge toggle via
the Harden action, clear UI copy on the discoverability tradeoff. Lowest priority.

## Sequencing

A + B are app-only and low-risk — ship first. Then C1. C2 → C3 is the substantive new build.
C4 last.

1. A (#403) → 2. B (#404) → 3. C1 (#405) → 4. C2 (#406) → 5. C3 (#407) → 6. C4 (#408)

## Testing

- A/B/C1: extend `csp.test.ts`, `pre-deploy-check.test.ts`, and new artifact-generator tests.
  Run `swift test` before pushing — string-match/smoke tests are coupled to template
  markup/headers.
- C2/C3: unit-test `SecurityAudit` and the change-plan/diff computation against a mocked
  `CloudflareClient`. No live-account calls in tests.

## Out of scope

- Rate limiting (broken for this use case; paid).
- Blanket automation/user-agent blocking.
- Non-Cloudflare hosting targets.
- App-binary signing/notarization (tracked separately under Phase 10.1).

## Sources

- [OWASP Secure Headers Project](https://owasp.org/www-project-secure-headers/)
- [Cloudflare Pages `_headers`](https://developers.cloudflare.com/pages/configuration/headers/)
- [Cloudflare WAF custom rules](https://developers.cloudflare.com/waf/custom-rules/)
- [Cloudflare — stop malicious bots (Free/Pro/Business)](https://developers.cloudflare.com/use-cases/solutions/stop-malicious-bots/)
- [EasyDMARC — DMARC best practices 2026](https://easydmarc.com/blog/dmarc-best-practices/)
