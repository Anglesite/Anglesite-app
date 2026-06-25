# RemoteSandboxSiteRuntime + in-container security (iOS) — design

**Date:** 2026-06-23
**Issues:** #66 (`RemoteSandboxSiteRuntime` + control plane) + #67 (remote preview security) — designed as one slice. Part of epic #59. Consumed by #71 (iOS thin client).
**Status:** Approved design; ready for implementation planning.

## Scope correction (read first)

This runtime is **iOS-only**. The earlier epic framing ("MAS takes the Cloudflare
fallback") is superseded by the owner's decision (2026-06-23):

- **macOS uses Apple Containerization** (`LocalContainerSiteRuntime`, #69) as *the*
  runtime — including the MAS build, which means #69 must eventually run under the App
  Sandbox (reopening #60's **Wall 3**: container networking without `vmnet`). That is a
  **separate, next-up macOS blocker** and is out of scope here.
- **The remote Cloudflare sandbox is only an option on iOS** (#71), which has no Apple
  Containerization, no Node, and no subprocesses.

So this design targets a device that can only make HTTPS calls and host a `WKWebView`.

## Goal

Let the iOS thin client open any Anglesite site, run its Astro dev server + the app-owned
Node MCP sidecar in a **Cloudflare Sandbox** in the *user's own* Cloudflare account, show
the live preview in a `WKWebView`, and drive edits over the in-container MCP server — with
every session gated by an app-minted bearer token.

## Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Substrate | Cloudflare Sandbox (`@cloudflare/sandbox`) in the **user's account**; user bills | Matches epic "BYO token, remote bills the user"; zero Anglesite-operated infra |
| Exposure | Per-port **quick tunnels** (`sandbox.tunnels.get(port)` → `*.trycloudflare.com`) | Zero-config, no custom domain / wildcard DNS; works on `.workers.dev` |
| Authz home | **In-container** (auth-proxy for preview, bearer check in MCP sidecar) | Quick tunnels bypass the Worker, so the Worker can't validate — see "Exposure ⇄ auth" below |
| Provisioning | One-time **Deploy-to-Cloudflare** flow against an Anglesite-maintained template repo | iOS can't build/push a container image or run wrangler; CF does it hosted |
| Image | **amd64** OCI, built + pushed **Cloudflare-side** from the template repo | Cloudflare Containers require `linux/amd64`; iOS can't build images |
| Source of truth | Git — sandbox `git clone`s `Source/`; cold re-hydrate on eviction | #72; survives `sleepAfter` disk loss |

## Research findings that drive the design (Cloudflare docs, 2026-06)

1. **Container architecture is amd64-only.** *"Your container image must be able to run on
   the `linux/amd64` architecture"*
   ([get-started](https://developers.cloudflare.com/containers/get-started/)). The local leg
   (#69, Apple Silicon) is arm64, so the shared image is multi-arch overall, but the **remote
   leg is amd64**, built Cloudflare-side here.
2. **Exposure ⇄ auth tension.** `exposePort()` + `proxyToSandbox()` route every HTTP/WS
   request through the Worker (so it *could* validate a token, via the SDK's
   `validatePortToken()` / `wsConnect()`) **but require a custom domain with wildcard DNS**.
   `sandbox.tunnels.get(port)` gives a zero-config `*.trycloudflare.com` URL but the traffic
   goes cloudflared→client, **bypassing the Worker**
   ([ports](https://developers.cloudflare.com/sandbox/api/ports/),
   [tunnels changelog 2026-05-29](https://developers.cloudflare.com/changelog/post/2026-05-29-sandbox-named-tunnels/)).
   We chose tunnels → **authz must live in-container.**
3. **Container lifecycle.** `sleepAfter` idle-stops the instance; **container disk is lost on
   sleep** (only Durable-Object `ctx.storage` persists). Snapshot/resume is **not documented
   as reliable** → assume cold re-hydrate (Git clone + baked `node_modules`) on every cold
   start ([containers](https://developers.cloudflare.com/containers/), get-started).
4. **Instance types.** `lite` (1/16 vCPU, 256 MiB) … `standard-4` (4 vCPU, 12 GiB, 20 GB),
   plus custom (GA)
   ([limits](https://developers.cloudflare.com/containers/platform-details/limits/)).
   `astro dev` + Node + sharp → floor is `standard-1`/`standard-2`; confirm under load.
5. **Provisioning without wrangler.** Workers can be deployed via REST/JSON API or the
   **Deploy-to-Cloudflare button** (`deploy.workers.cloudflare.com/?url=<template>`), which
   provisions Worker + Durable Objects (and builds/pushes the container image) into the user's
   account via browser OAuth
   ([new Workers API](https://developers.cloudflare.com/changelog/post/2025-09-03-new-workers-api/)).

## Architecture

```
 iOS thin client (#71)                       User's Cloudflare account
 ┌─────────────────────────┐  Deploy-to-CF   ┌────────────────────────────────────┐
 │ Onboarding              │──(browser OAuth)▶│ Control Worker + Sandbox DO         │
 │  • store Worker URL+token│                 │  (from Anglesite template repo;     │
 │                          │                 │   CF builds/pushes amd64 image)     │
 │ RemoteSandboxSiteRuntime │   HTTPS control │  ┌──────────────────────────────┐  │
 │   : SiteRuntime (#64)    │────start/stop──▶│  │ Container (amd64 OCI)         │  │
 │   • mint sessionToken    │                 │  │  auth-proxy :8080 ◀─tunnel──┐ │  │ preview URL
 │   • start/stop/observe    │                │  │    └─▶ astro dev :4321       │ │  │
 │   • mcpEndpoint           │   tunnel URLs  │  │  MCP sidecar :4399 ◀─tunnel─┼─┘  │ mcp URL
 │ WKWebView(UIViewRep.)     │◀──HTTPS/WS(cookie=token)─▶ auth-proxy (validates cookie)
 │ MCPClient(Bearer token)   │◀──HTTPS/WS(Authorization: Bearer)─▶ MCP sidecar (validates)
 └─────────────────────────┘                 └────────────────────────────────────┘
```

## Components (units, with one clear purpose each)

1. **`RemoteSandboxSiteRuntime`** (AnglesiteCore) — implements `SiteRuntime` (#64). Owns the
   session: mints the token, calls the Control Worker to start/stop, observes state, exposes
   `mcpEndpoint`. Depends on a `SandboxControlClient` (below) and `SessionToken`.
2. **`SandboxControlClient`** (AnglesiteCore, protocol + HTTPS impl) — thin typed wrapper over
   the Control Worker's RPCs (`start`, `stop`, `status`). The protocol seam is what unit tests
   fake — no Cloudflare in tests.
3. **Control Worker** (new repo/dir: the Anglesite template) — `@cloudflare/sandbox` host:
   the Sandbox Durable Object + `start`/`stop`/`status` routes. On `start`: `getSandbox(id =
   user+site)`, `git clone` the `Source/` repo at `gitRef`, hydrate, `startProcess` the three
   in-guest processes (token in env), then open two tunnels: **`tunnels.get(8080)` for the
   preview (the auth-proxy port — *not* astro's 4321; tunneling 4321 directly would expose the
   dev server unauthenticated)** and `tunnels.get(4399)` for MCP. Return the two URLs. Deployed
   once per user via the Deploy button.
4. **In-guest auth-proxy** (OCI image) — small reverse proxy in front of `astro dev` that
   validates the session token (as a **cookie**, so HMR WebSocket upgrades and asset requests
   from the `WKWebView` all carry it) and forwards. This is where #67's preview authz lives.
5. **MCP sidecar bearer check** (app-owned Node sidecar, already HTTP per #63) — validates
   `Authorization: Bearer <token>` on HTTP **and** WS upgrade; rejects otherwise.
6. **`SessionToken`** (AnglesiteCore) — 256-bit opaque (CryptoKit random), minted per session,
   passed into the sandbox as an env secret, never logged. Symmetric compare in-guest (no
   asymmetric crypto needed).
7. **Onboarding** (iOS) — Deploy-to-Cloudflare flow (open in `ASWebAuthenticationSession` /
   in-app browser) + capture of the Worker URL and an API token (reuse #207's verify-then-
   persist pattern; expanded token scope).

## Data flow

- **Provision (once):** user taps "Connect Cloudflare" → Deploy-to-CF button (template repo)
  → CF builds/pushes the amd64 image + deploys the Worker+DO into their account → app stores
  Worker URL + API token in the Keychain.
- **Start session:** mint `SessionToken` → `SandboxControlClient.start(site, gitRef, token)` →
  Worker boots the sandbox, hydrates from Git, starts the 3 processes, opens 2 tunnels,
  returns `{previewURL, mcpURL}` → app injects the token as a cookie into the `WKWebView`
  cookie store, loads `previewURL`; `MCPClient.connect(httpEndpoint: mcpURL)` with the bearer
  header → state `.ready(url:)`.
- **Edit:** unchanged app-side — `apply_edit`/`undo_edit` over the authenticated MCP tunnel.
- **Teardown (Q-C — shared lifetime):** view/tab close → `SandboxControlClient.stop` (drop
  tunnels, let the sandbox sleep) → discard the token. Idle → `sleepAfter` stops it; next open
  is a cold re-hydrate with a fresh token + fresh tunnels.

## Error handling & edge cases

- **No token / not provisioned** → route to onboarding, don't attempt a session.
- **Worker unreachable / token invalid** → surface a clear "reconnect Cloudflare" state;
  never silently retry into a billing loop.
- **Cold start slow / hydrate fallback** → `.starting` state drives a determinate-ish progress
  UI; if baked `node_modules` doesn't match the lockfile, fall back to `npm ci` (slower; log
  it, don't fail).
- **Tunnel/auth mismatch** → a 401/403 from the auth-proxy or MCP sidecar tears the session
  down rather than showing a half-authed preview.
- **Sandbox evicted mid-session** → observe loss, re-hydrate transparently or prompt.

## Testing

- **`RemoteSandboxSiteRuntime`** against a **faked `SandboxControlClient`**: start/stop/observe
  state machine, token minting, teardown ordering, error mapping. No Cloudflare. Runs under
  `swift test` on CI.
- **In-guest auth** (auth-proxy + MCP bearer): unit tests reject missing/wrong token on HTTP
  **and** WS upgrade; accept valid; cookie vs header paths.
- **One opt-in live integration test** (gated on a real account token, like the existing e2e
  gates): boots a real sandbox, asserts preview loads, **HMR over the tunnel WebSocket**, and
  an authenticated MCP round-trip. This finally retires the #61 spike's unmeasured TBDs.

## Open items (verify during implementation; non-blocking)

- Exact Cloudflare **token permission groups** for Containers + Durable Objects + Workers
  Scripts (and image push for the deploy step — the Deploy button handles push). Manual-verify
  like the #207 onboarding-URL gate.
- **Instance-type floor** (`standard-1` vs `standard-2`) — measure RAM under `astro dev` +
  sharp in the live test.
- **Template repo** location + maintenance (the Control Worker + Dockerfile that the Deploy
  button targets); how its image digest tracks the canonical image (#62).

## Epic touchpoints

- **#64 `SiteRuntime`** — this drops in as the second impl (alongside #69). `PreviewView` is
  already `URL`-only, so it's portable.
- **#63/#65 MCP-over-HTTP** — reused as-is; the sidecar gains the bearer check.
- **#69 / #60 Wall 3** — the macOS local runtime is the separate next blocker (MAS App Sandbox
  networking). Not addressed here.
- **#71 iOS target** — this runtime ships *in* it; depends on the iOS shell existing.
- **#70 host-Node retirement** — unaffected on iOS (no host Node there at all).
