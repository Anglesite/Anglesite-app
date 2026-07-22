# iOS Deploy-to-Cloudflare onboarding — design

**Date:** 2026-07-21
**Issue:** #71 follow-up (tracked in the issue's latest comment alongside the UIKit Siri-annotation
provider, multi-site UX, and the live e2e smoke test). Builds on the iOS thin client shipped in
#885/#886 and the runtime design in
[`2026-06-23-remote-sandbox-runtime-ios-design.md`](2026-06-23-remote-sandbox-runtime-ios-design.md).
**Status:** Approved design; ready for implementation planning.

## Scope

The 2026-06-23 runtime design's onboarding component reads: *"Deploy-to-Cloudflare flow (open in
`ASWebAuthenticationSession` / in-app browser) + capture of the Worker URL and an API token (reuse
#207's verify-then-persist pattern; expanded token scope)."* That flow assumes a **Control Worker
template repo** (the `@cloudflare/sandbox`-hosting Worker + Durable Object + Dockerfile that a
Cloudflare "Deploy to Cloudflare" button would provision) — and no such repo exists yet anywhere
under the `Anglesite` org. Building it is a separate, larger effort (new Wrangler project, DO
`start`/`stop`/`status` routes, in-guest auth-proxy, image-digest tracking against #62) and is
**explicitly out of scope here**, tracked as its own future issue.

This slice is **app-side only**: it replaces the current `RemoteConnectForm`'s blind paste-and-save
fields with a real verify-then-persist connect flow, adds a way to obtain the Control Worker bearer
token via Cloudflare OAuth instead of only pasting one, and adds a small piece of new
infrastructure (a callback Worker) that the OAuth flow needs to function on iOS. It does **not**
stand up a real Control Worker, so the full live round-trip (OAuth → paste target → `start` a real
sandbox) can't be end-to-end tested until the template repo exists — same caveat #886 already
carries for its own live-smoke follow-up.

## Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Control Worker template | Out of scope | Doesn't exist; a separate, larger effort |
| "Deploy to Cloudflare" button | Points at Cloudflare's real Containers get-started docs, relabeled "Cloudflare Container Setup Guide" | Honest interim target — nothing actually deploys yet, so the button must not claim otherwise |
| Token capture | Verify-then-persist (mirrors `TokenOnboarding`/`GitHubTokenOnboarding`), *plus* an OAuth path to fill the same field | Manual paste stays as the baseline; OAuth is an additional way to populate it, not a replacement |
| OAuth mechanism | Cloudflare self-managed OAuth clients (opened to all developers 2026-06-03), Authorization Code + PKCE, public client, `token_endpoint_auth_method: none` | Native-app-appropriate; no client secret to protect |
| OAuth redirect | `https://auth.anglesite.dwk.io/oauth-callback` via Apple Associated Domains, not a custom URL scheme | Cloudflare's OAuth-client form rejects non-`http(s)` redirect URIs |
| Callback hosting | New small Cloudflare Worker (`Workers/anglesite-oauth-callback/`), unrelated to the Sandbox/Container template | Two static routes (AASA + fallback page); no reason to wait on the big template |

## Components

### 1. `SandboxControlOnboarding` (AnglesiteCore, new)

Mirrors `TokenOnboarding`/`GitHubTokenOnboarding`'s verify → persist → flash → re-check-cancel →
proceed ordering (`@MainActor` struct, same shape). Verification reuses the existing
`SandboxControlClient.status(siteID:)` — no new server API needed:

- `SandboxControlError.unauthorized` → `.stay(message: "That token was rejected by the Worker.")`
- `SandboxControlError.unreachable` → `.stay(message: "Couldn't reach the Worker: …")`
- any other throw → `.stay` with a generic message
- success → `persist` closure runs, then `onConnected` → `delay` → cancellation re-check → `.proceed`

Testable under `swift test` against the existing `FakeSandboxControlClient` fixture. `persist`,
`onConnected`, `delay`, `isCancelled` are injected closures, same pattern as the two existing
onboarding types.

### 2. `RemoteSessionModel` changes (AnglesiteMobile)

Today, `RemoteConnectForm`'s `TextField`s bind straight to `model.workerURLString` /
`model.controlToken` / `model.siteID`, which persist on every keystroke via `didSet` — no
validation at all. This changes:

- The three fields move to local `@State` drafts in the view, seeded from the model's current
  values.
- A new `connect(workerURLString:token:siteID:)` async method wraps `SandboxControlOnboarding`,
  exposing `connectionCheck: .idle | .checking | .connected | .failed(message:)` for the UI.
- Only on `.proceed` does it assign into the existing persisted properties (`workerURLString =`,
  `controlToken =`, `siteID =`), which persist exactly as they do today (UserDefaults / Keychain
  `didSet`) — no storage-layer changes.
- Git remote/ref fields are untouched — still directly bound, still auto-saving. They're not part
  of the verified secret pair and there's nothing to verify them against.

### 3. `RemoteConnectForm` UI changes (AnglesiteMobile)

The Cloudflare Control Worker section gains:

```
[ Cloudflare Container Setup Guide ]   ← opens Cloudflare's Containers get-started docs
[ Connect via Cloudflare            ]   ← OAuth path, fills the token draft (see §5)

Worker URL:  [ https://…workers.dev        ]
Token:       [ ••••••••••••••••            ]
Site ID:     [ my-site                     ]

[         Connect         ]
  ↳ spinner → "Reached your Worker" / inline error text
```

`Connect` is disabled until all three drafts are non-empty. `.checking` shows a spinner and
disables the fields; `.connected` briefly flashes a confirmation before settling back to idle
(mirrors the macOS token-prompt's flash-then-settle); `.failed(message:)` shows the message inline,
fields stay editable. The Git section below is unchanged.

### 4. Setup-guide button

Opens `https://developers.cloudflare.com/containers/get-started/` (confirmed live, current) via
SwiftUI's `webAuthenticationSession` environment action for an in-app browser sheet rather than
kicking out to Safari. No real callback is expected from this one — the user reads the guide and
dismisses manually; the resulting cancellation error is swallowed silently, not surfaced. A code
comment notes this is an interim target until the Control Worker template repo ships (tracked
separately), so swapping the URL later is a one-line change. Labeled "Cloudflare Container Setup
Guide," not "Deploy to Cloudflare" — tapping it doesn't deploy anything.

### 5. `CloudflareOAuthClient` (AnglesiteCore, new)

Implements Authorization Code + PKCE against Cloudflare's OAuth provider:

1. Fetch `https://dash.cloudflare.com/.well-known/openid-configuration` once for
   `authorization_endpoint` / `token_endpoint` (discovery, not hardcoded paths — standard OIDC
   practice, survives Cloudflare relocating them).
2. Generate a `code_verifier` / `code_challenge` (S256, CryptoKit) and a `state` nonce — pure,
   no network, unit-testable in isolation.
3. Build the authorize URL (`response_type=code`, `client_id`, the registered redirect URI, scope,
   `state`, `code_challenge`, `code_challenge_method=S256`).
4. Present it via `ASWebAuthenticationSession` using the `.https(host: "auth.anglesite.dwk.io",
   path: "/oauth-callback")` callback matcher (iOS 17.4+ API; well under this app's iOS 27 floor).
   Whether SwiftUI's `webAuthenticationSession` environment action exposes this `.https` overload
   directly, or whether the raw `ASWebAuthenticationSession` API (with a presentation-context
   provider) is needed instead, is an implementation-time detail — doesn't change the design.
5. Parse `code` / `state` off the returned callback URL; reject on `state` mismatch.
6. Exchange `code` + `code_verifier` at the token endpoint (`grant_type=authorization_code`,
   `client_id`, redirect URI) for an access token.

The resulting access token fills the same token draft field the paste flow uses (§3) — it does not
bypass `SandboxControlOnboarding`'s verify step. One state machine, two ways to populate it.

**Client registration** is a Cloudflare-dashboard action on the app maintainer's own account —
outside this codebase and outside what an agent can do (it's a third-party account/domain
action requiring dashboard login). Concretely: client name "Anglesite," grant type Authorization
Code, response type `code`, token endpoint auth method `none` (confirmed: Cloudflare's own guidance
maps "browser-based, mobile, desktop, or CLI app" → PKCE → `none`), redirect URI
`https://auth.anglesite.dwk.io/oauth-callback`. The client must be flipped to **public** visibility
(any Anglesite user's own Cloudflare account needs to authorize it, not just the registering
account), which requires DNS TXT domain-ownership verification plus branding fields (logo, policy
URI, ToS URI). The resulting `client_id` (no secret — PKCE public clients don't get one) becomes an
app-side constant once issued.

### 6. Callback Worker (new, small)

A minimal Wrangler project at `Workers/anglesite-oauth-callback/` in this repo — unrelated to
`container/` (the Sandbox/Container template's build context). Two static routes, no state, no
`@cloudflare/sandbox`:

- `GET /.well-known/apple-app-site-association` — JSON naming the app's Team ID + bundle ID
  (`io.dwk.anglesite.ios`) under a `webcredentials` entry.
- `GET /oauth-callback` — plain fallback HTML ("You can close this and return to Anglesite") for
  cases where iOS doesn't intercept the navigation before it loads.

Written as part of this slice; deployed to `auth.anglesite.dwk.io` (DNS + `wrangler deploy`) by
the app maintainer, same division of labor as the OAuth client registration.

### 7. iOS entitlements (AnglesiteMobile)

`AnglesiteMobile` currently has **no entitlements file** (`CODE_SIGN_ENTITLEMENTS` unset in
`project.yml`). This adds `Resources/AnglesiteMobile.entitlements` with
`com.apple.developer.associated-domains = ["webcredentials:auth.anglesite.dwk.io"]`, wired into
`project.yml`.

**Known risk, not resolved here:** `AnglesiteMobile`'s Debug config uses ad-hoc signing
(`CODE_SIGN_IDENTITY: "-"`). Associated Domains is an App-ID-level capability that normally needs a
real provisioning profile; it may not function under ad-hoc/manual signing at all. This can't be
verified without a properly provisioned build (no Apple Developer Portal access from an agent) —
carried as an open item.

## Data flow

- **Setup guide:** tap "Cloudflare Container Setup Guide" → in-app browser → user reads docs,
  dismisses manually. No app-state change.
- **OAuth connect:** tap "Connect via Cloudflare" → `CloudflareOAuthClient` runs discovery → PKCE
  authorize → (system may intercept the `https://auth.anglesite.dwk.io/oauth-callback` redirect via
  Associated Domains, or the callback Worker's fallback page renders) → token exchange → access
  token fills the token draft field.
- **Connect (verify-then-persist):** tap "Connect" → `SandboxControlOnboarding.run()` calls
  `SandboxControlClient.status(siteID:)` against the pasted/OAuth-obtained Worker URL + token →
  on success, persists into `RemoteSessionModel`'s existing storage (UserDefaults / Keychain,
  unchanged) → confirmation flash → settles.
- **Open Site:** unchanged from #886 — `model.start()` once `isConfigured`.

## Error handling & edge cases

- OAuth cancel/deny → normal abort, no error toast.
- OAuth `state` mismatch → hard fail, discard, surface a generic "connection attempt failed" —
  never silently accept a mismatched state.
- OAuth discovery/token-endpoint network failure → surfaced inline, same treatment as a failed
  paste-verify.
- `SandboxControlOnboarding` failures (`.unauthorized` / `.unreachable` / other) → per §1.
- A cancelled connect attempt (view torn down / user backs out mid-flow) must not silently persist
  a partially-verified token — mirrors the exact bug `TokenOnboarding`'s ordering was built to
  prevent on macOS.

## Testing

- `SandboxControlOnboardingTests` — mirrors `TokenOnboardingTests`, against
  `FakeSandboxControlClient`. Runs under `swift test`.
- `CloudflareOAuthClientTests` — PKCE verifier/challenge generation, discovery-doc parsing,
  `state`-mismatch rejection, token-exchange request shape, all against a stubbed `URLSession`. No
  live network. Runs under `swift test`.
- Callback Worker — unit/smoke test of the two static routes, using this repo's existing
  Workers-testing conventions (Vitest + Miniflare).
- **Not covered by automated tests** (flagged, not silently skipped): the live
  authorize→callback→token round trip against a real registered OAuth client; Associated Domains
  behavior under real (non-ad-hoc) provisioning; and the full `start()` path against a real
  Control Worker, which still doesn't exist.

## Open items (verify during implementation; non-blocking)

- OAuth scope for v1.0: **User Details (Read)** only — this token authenticates the user to their
  own Control Worker's custom routes; the app itself never calls Cloudflare's management API with
  it, so broader scopes (Workers Scripts, Durable Objects, Containers) aren't justified yet per
  Cloudflare's own "request only what you need" guidance. Request the minimal scope during #890's
  implementation and widen it later, empirically, if a concrete need shows up — cheaper than
  guessing broader scopes upfront and matches how OAuth scope creep is normally handled.
- Whether SwiftUI's `webAuthenticationSession` environment action exposes an `.https(host:path:)`
  overload, or whether raw `ASWebAuthenticationSession` is needed for that callback variant.
- Whether Associated Domains functions at all under `AnglesiteMobile`'s current ad-hoc Debug
  signing, or whether a real provisioning profile is required even for local testing.

## Epic touchpoints

- **#71 iOS thin client** — this is a direct follow-up to #885/#886.
- **2026-06-23 remote-sandbox-runtime-ios-design** — this slice implements that design's
  "Onboarding" component, minus the Control-Worker-template half.
- **#207** — the verify-then-persist pattern this reuses.
- **Control Worker template (future issue, not yet filed)** — the remaining, larger piece; the
  Deploy-to-Cloudflare button and full OAuth-token-as-Worker-auth design belong there once it
  exists.
