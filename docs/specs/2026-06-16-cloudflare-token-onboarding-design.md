# Cloudflare token onboarding — guided paste design

**Date:** 2026-06-16
**Status:** Implemented (PR #207)
**Area:** `AnglesiteApp` (token prompt UI, `DeployModel`), `AnglesiteCore` (new token verifier)

## Problem

When a site needs a Cloudflare API token, `DeployModel` surfaces `CloudflareTokenPromptView`
(`Sources/AnglesiteApp/CloudflareTokenPromptView.swift`). Today that dialog:

- Links to the bare token *list* page (`https://dash.cloudflare.com/profile/api-tokens`), leaving
  the user to discover "Create Token", pick a template, and guess which permissions a Workers
  deploy needs.
- Gives **no inline instructions** — the single biggest reason first-time users get lost here.
- Validates the token only for non-emptiness (`CloudflareTokenPromptView.swift:59`). A wrong but
  non-empty token is written straight to the Keychain (`DeployModel.saveTokenAndRetry`,
  `DeployModel.swift:93`) and fails later inside `wrangler deploy` with a cryptic error — and the
  bad token persists, so the next deploy re-fails the same way.

## Goals

1. Get a correct token pasted in under a minute, with no Cloudflare knowledge required.
2. Catch a bad token at the point of entry with a clear, specific message — never persist one.
3. Confirm success concretely by naming the connected Cloudflare account.

## Non-goals (YAGNI)

- No OAuth / "Sign in with Cloudflare" flow (re-architects auth; collides with the MAS sandbox).
- No raw Cloudflare REST networking in Swift (would need `com.apple.security.network.client`
  re-justified for the sandboxed target).
- No multi-account picker — `wrangler whoami` reports the resolved account; that is enough.
- No change to `DeployCommand`'s `CLOUDFLARE_API_TOKEN` env-var contract or `KeychainStore` slots.

## What the site actually deploys

`template/wrangler.jsonc` is a **Workers + Static Assets** deployment (`wrangler deploy`). The
optional IndieWeb features (provisioned separately by `/anglesite:indieweb`) add D1, R2, and Queues.
The base deploy that this prompt blocks on maps exactly onto Cloudflare's built-in **"Edit
Cloudflare Workers"** token template:

| Permission group        | Level | Resource |
|-------------------------|-------|----------|
| Workers Routes          | Edit  | Zone     |
| Workers Scripts         | Edit  | Account  |
| Workers KV Storage      | Edit  | Account  |
| Workers Tail            | Read  | Account  |
| Workers R2 Storage      | Edit  | Account  |

## Design

### 1. Redesigned dialog — `CloudflareTokenPromptView`

A guided, three-step layout replacing the terse prompt:

```
┌──────────────────────────────────────────────────────┐
│  Connect to Cloudflare                                │
│  Deploying needs a one-time API token. Takes about    │
│  a minute.                                             │
│                                                        │
│  1.  [ Open Cloudflare API tokens ↗ ]                  │
│  2.  The "Edit Cloudflare Workers" permissions should  │
│      already be selected (if not, pick that template). │
│      Click "Continue to summary".                      │
│  3.  Click "Create Token", then copy it and paste it   │
│      below.                                            │
│                                                        │
│  ┌──────────────────────────────────────────────────┐ │
│  │ paste token                                      │ │
│  └──────────────────────────────────────────────────┘ │
│                                                        │
│  ⟳ Checking token…   /   ✓ Connected to Acme Co.       │
│                                                        │
│                    [ Cancel ]   [ Connect & deploy ]   │
└──────────────────────────────────────────────────────┘
```

Copy/structure changes:

- Title "Connect to Cloudflare" (not "…required"); a time estimate to reduce dread.
- Three explicit numbered steps that name the **"Edit Cloudflare Workers"** template, so the flow
  reads as a recipe even if the pre-fill (below) is ever unavailable.
- Primary button renamed "Connect & deploy"; disabled while the field is empty **or** a
  verification is in flight.
- A status line under the field carries the three verification states (idle/checking/result).

### 2. Pre-filled token URL (progressive enhancement)

Step 1 links to a URL that reproduces the "Edit Cloudflare Workers" template with permissions
pre-checked and the name pre-filled:

```
https://dash.cloudflare.com/profile/api-tokens?name=Anglesite%20Deploy&accountId=*&zoneId=all&permissionGroupKeys=<url-encoded JSON>
```

Decoded `permissionGroupKeys`:

```json
[{"key":"workers_routes","type":"edit"},
 {"key":"workers_scripts","type":"edit"},
 {"key":"workers_kv_storage","type":"edit"},
 {"key":"workers_tail","type":"read"},
 {"key":"workers_r2","type":"edit"}]
```

**This URL format is undocumented.** It is treated strictly as a progressive enhancement:

- If Cloudflare honors it, the user lands on the create-token form with the five boxes checked and
  the name filled — they click through to "Create Token".
- If Cloudflare ever changes the schema, the same URL still lands the user on
  `/profile/api-tokens`, and the inline steps still name the exact template to select by hand. The
  flow degrades to guided-paste rather than breaking.

The encoded URL is built once as a Swift constant (single source of truth, easy to revise). The
permission JSON and `name` live as readable literals that are URL-encoded at build time, not
hand-encoded.

> **Implementation gate — SATISFIED (2026-06-16):** because the format is undocumented, it was
> verified manually against a real Cloudflare login. The Create Token form pre-fills all five
> permission rows (Workers Routes/Scripts/KV/Tail/R2), the name "Anglesite Deploy", and
> Include-all-accounts / Include-all-zones. (It can't be verified headlessly — the form renders
> behind dashboard auth.) Note: the query string must be passed intact; line breaks introduced by
> copy/paste corrupt `permissionGroupKeys` and silently drop the whole permission list.

### 3. Live verification via `wrangler whoami`

New type in `AnglesiteCore`, e.g. `CloudflareTokenVerifier`:

- **Input:** the trimmed token and the site directory.
- **Action:** runs the site's own wrangler (`node node_modules/.bin/wrangler whoami`) through
  `ProcessSupervisor.shared.run(...)` with `CLOUDFLARE_API_TOKEN` set in the environment and
  `currentDirectoryURL` = the site dir — mirroring how `DeployCommand` resolves and launches
  wrangler (`DeployCommand.swift:309`, `:133`, `:297`). This reuses the one supervised spawn path
  (so the MAS sandbox's per-site grant is inherited) and adds no Swift networking.
- **Output:** `Result<CloudflareAccount, VerifyError>` where `CloudflareAccount` carries the parsed
  account name (and email if present).

**Resolution / injection.** Verification is exposed behind a small protocol (a
`TokenVerifying` seam) and injected into `DeployModel`, defaulting to the wrangler-backed
implementation — matching the existing `command`/`logCenter`/`keychain` injection in
`DeployModel.init` (`DeployModel.swift:51`). Tests stub it without spawning Node.

**Parsing.** `wrangler whoami` prints a bordered table including an account-name column and the
account email. The parser extracts the account name from that output. Parsing lives in a pure
function fed raw stdout so it is unit-testable against captured fixtures, and is defensive: if the
exit code is 0 but no name can be parsed, fall back to a generic "✓ Token verified" rather than
failing a known-good token.

### 4. Flow changes — `DeployModel`

`saveTokenAndRetry` (currently synchronous, writes the Keychain unconditionally) is replaced by an
**async verify-then-persist** path:

1. Trim; reject empty (unchanged guard).
2. Set state to `.checking` (drives the spinner; disables the button).
3. Call the verifier with the token + the parked deploy's `siteDirectory` (already captured in
   `pendingDeploy`, `DeployModel.swift:49`).
4. **Success:** write the token to the Keychain *now* (not before), set state to
   `.connected(accountName)`, dismiss the sheet, and dispatch the parked deploy — same retry
   handoff as today (`DeployModel.swift:102`).
5. **Failure:** set state to `.error(message)`, keep the sheet open, **do not touch the Keychain**.

New observable verification state on `DeployModel` (or a small view-owned state object) with cases
`idle | checking | connected(String) | error(String)`, consumed by the dialog's status line and
button-enabled logic.

### 5. Error mapping

`VerifyError` → user-facing copy:

- Auth failure (non-zero exit / wrangler "Unable to authenticate" / "Invalid request headers") →
  *"That token didn't work. Make sure you picked the 'Edit Cloudflare Workers' template and copied
  the whole token."*
- Network/unreachable → *"Couldn't reach Cloudflare. Check your connection and try again."*
- Spawn failure (wrangler/Node missing) → reuse the existing
  *"wrangler not installed — run `npm install`…"* style remediation.

The token value is never logged (consistent with `KeychainStore.swift:19` and the env-dict opacity
note in `DeployCommand`).

## Data flow

```
Deploy click
  └─ no token → CloudflareTokenPromptView (deploy parked in pendingDeploy)
       1. "Open Cloudflare API tokens" → browser (pre-filled template URL)
       2/3. user creates token, copies, pastes
       "Connect & deploy"
         └─ DeployModel: state=.checking
              └─ CloudflareTokenVerifier: wrangler whoami (ProcessSupervisor, token in env, cwd=site)
                   ├─ success → parse account → Keychain write → state=.connected(name)
                   │             → dismiss → run parked deploy
                   └─ failure → state=.error(msg) → sheet stays, Keychain untouched
```

## Testing

The verification logic *and* the verify→persist→proceed orchestration both live in `AnglesiteCore`
(a real test target) precisely so they can be unit-tested under `swift test` — which runs on CI's
macOS-15 runners. `DeployModel` is a thin `@MainActor` forwarder over `TokenOnboarding`; the view
stays build-covered. (Hosting `DeployModel` tests inside `Anglesite.app` was rejected: launching a
macOS-27 app on the macOS-15 CI runner is blocked by LaunchServices, so a hosted test target can't
run in CI today.)

- **Parser unit tests** (`AnglesiteCoreTests/CloudflareTokenVerifierTests`): account-name and email
  extraction from captured `wrangler whoami` stdout fixtures (with and without an email line),
  including the no-table → `nil` case so a zero-exit run still verifies.
- **Failure-classification tests:** auth output → `.invalidToken`, DNS/connection output →
  `.network`.
- **Error-copy tests:** `.invalidToken` names the "Edit Cloudflare Workers" template; `.network`
  mentions the connection.
- **Verify-orchestration tests** with an injected runner (no Node spawned): zero-exit → parsed
  account; zero-exit-but-unparsable → success with `nil` name; non-zero auth → `.invalidToken`;
  thrown runner → `.unavailable`.
- **`TokenOnboarding` orchestration tests** (`AnglesiteCoreTests/TokenOnboardingTests`, stubbed
  verifier + injected `persist`/`isCancelled`): a non-cancelled verified token → `.proceed`
  (persisted once); cancellation after verify → `.abort` (no proceed); failed verify → `.stay`
  (never persists); empty token → `.stay` without verifying; a throwing `persist` → `.stay`. The
  cancel-race is asserted deterministically via the injected `isCancelled`, not a timing window.
- **Build verification:** `swift test` (Core) plus `xcodebuild` of both the `Anglesite` and
  `AnglesiteMAS` schemes — the MAS target builds clean since no new entitlement is introduced
  (verification reuses the existing supervised wrangler spawn).

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Undocumented pre-fill URL stops working | Degrades to plain token page + named-template steps; manual gate before ship |
| `wrangler whoami` output format changes | Parser is defensive; exit-0 with unparsable name → generic "verified", token still accepted |
| Verification latency (network) | `.checking` spinner; button disabled; same network the deploy would use anyway |
| MAS sandbox blocks the whoami spawn | None new — reuses the existing supervised wrangler path the deploy already relies on |

## Files touched

- `Sources/AnglesiteApp/CloudflareTokenPromptView.swift` — rewritten (steps, states, copy, URL).
- `Sources/AnglesiteApp/DeployModel.swift` — async verify-then-persist; verification state; verifier
  injection.
- `Sources/AnglesiteCore/CloudflareTokenVerifier.swift` *(new)* — `TokenVerifying` protocol,
  `WranglerTokenVerifier` impl, pure stdout parser, `CloudflareAccount`, `TokenVerifyError`.
- `Sources/AnglesiteApp/SiteWindow.swift` — only if the sheet wiring needs the new state (likely
  unchanged; binding stays `$deploy.tokenPromptPresented`).
- Tests under `AnglesiteCoreTests` (parser, error mapping) and the `DeployModel` suite.
