# Cloudflare Sandbox dev server (toward Anglesite on iOS) — Investigation / Design

> **Status:** investigation. No implementation committed. This captures the findings
> of the "run the dev server in a Cloudflare Sandbox so Anglesite can run on iOS"
> spike and proposes a phased path. **The OPEN decisions were resolved 2026-05-30 —
> see §7.** Next artifact is a `…-plan.md`.

## Decisions (resolved 2026-05-30)

| # | Decision | Choice |
|---|---|---|
| 1 | Durable substrate | **Git remote** — the sandbox `git clone`s on start, edits commit/push, the source of truth is the repo. |
| 2 | Scope | **Replace** — remote-everywhere; drop the embedded Node / local subprocess path once remote is proven. macOS and iOS both use `RemoteSiteRuntime`. |
| 3 | Preview authz | **Per-session bearer token** issued by the app, validated by the proxy Worker. |
| 4 | Account/billing | **Per-user BYO Cloudflare token** (reuse the existing Keychain `CLOUDFLARE_API_TOKEN`). |
| 5a | Preview URL exposure | **Per-session Cloudflare Tunnel** — no wildcard-DNS custom domain required, so no per-user domain onboarding. |
| 5b | Cold-start latency | **Container snapshots when available** (restore disk, skip `npm ci`); a "warming…" UX is the fallback until snapshots ship. |

**Consequence of #2 (Replace):** even macOS now needs network + the user's Cloudflare
account to preview — no offline editing. The `CLAUDE.md` rule "the filesystem is the
source of truth / the app must never be the only way to edit a site" is **reframed to
"Git is the source of truth"**: the repo (and any local `git clone` of it — Finder,
VS Code, Claude Code CLI) remains a real, externally-editable working copy, so the
*spirit* of the rule holds even though the app no longer drives a local `~/Sites`
working tree directly. **This reframing must be reflected in `CLAUDE.md` when the
plan lands.**

**Consequence of #5a (Tunnel):** §3.3's wildcard-DNS caveat is moot — the tunnel
supplies the hostname; our bearer token (#3) supplies the authz.

**Motivation:** The app today runs the Astro dev server (and the plugin's MCP
server) as *local subprocesses* via a vendored Node runtime. That model cannot
exist on iOS — iOS forbids `fork`/`exec` of arbitrary executables and ships no
embeddable general-purpose Node. If the dev server runs *off-device* in a
[Cloudflare Sandbox](https://developers.cloudflare.com/sandbox/) container and the
app becomes a thin client pointed at a preview URL, the same product can run on
iPad/iPhone — and, as a bonus, on a Mac without a 100+ MB embedded Node.

---

## 1. How the dev server runs today (what we'd be replacing)

The whole runtime is coupled to *spawning local processes against a local
filesystem*. The relevant seams, inner-to-outer:

| Layer | File | Responsibility | iOS-portable? |
|---|---|---|---|
| Spawn mechanism | `Sources/AnglesiteCore/InProcessBackend.swift` | `Process()` + pipes + restart loop | ❌ no `Process` on iOS |
| `SupervisorBackend` protocol | `Sources/AnglesiteCore/SupervisorBackend.swift` | seam over the spawn mechanism (`runOneShot`, `launch`, `waitForExit`, stdin, terminate) | ⚠️ the *protocol* is portable; its semantics ("a local pid, stdout/stderr pipes") are not |
| `ProcessSupervisor` | `ProcessSupervisor.swift` | shared facade over a `SupervisorBackend` | inherits the above |
| `AstroDevServer` | `AstroDevServer.swift` | spawns `node node_modules/.bin/astro dev`, scrapes `Local http://localhost:4321/` off stdout, HTTP-probes it, republishes the URL on supervised restart | ❌ stdout-scraping + localhost assumption |
| `MCPClient` | `MCPClient.swift` | JSON-RPC 2.0 over the subprocess's **stdio**; parses protocol lines back out of `LogCenter` | ❌ stdio transport |
| `PreviewSession` | `PreviewSession.swift` | orchestrates one site: resolves the launch command, starts `AstroDevServer`, starts the MCP client with `ANGLESITE_PROJECT_ROOT=<siteDir>`, exposes `State` (`idle/starting/ready(url)/failed`) | ✅ **this is the real seam** — see §4 |
| `NodeRuntime` | `NodeRuntime.swift` | locates the vendored Node binary in the bundle | ❌ vendored Node |
| `PreviewView` | `Sources/AnglesiteApp/PreviewView.swift` | `NSViewRepresentable` → `WKWebView`, `load(URLRequest(url:))`, reloads when `url` changes | ⚠️ `WKWebView` exists on iOS, but this is `NSViewRepresentable` (AppKit) |

Two design rules from `CLAUDE.md` bear directly on this work:

- **"The filesystem is the source of truth — the app must never become the only
  way to edit a site."** Owners can open `~/Sites/<name>/` in Finder/VS Code/Claude
  Code CLI. A remote container's disk is **not** that filesystem.
- **"The app cannot bypass plugin security hooks"** — `pre-deploy-check.sh` runs
  before every deploy. That hook is Node, and would have to run *in the sandbox*.

Also note the macOS app already integrates Cloudflare for **deploys**:
`DeployCommand.swift` shells out to `wrangler deploy` with a Keychain-stored
`CLOUDFLARE_API_TOKEN` (`CloudflareTokenPromptView`, `KeychainStore`). So a
Cloudflare account/token is already part of the product surface — reusable here.

There is **no iOS target, no `#if os(iOS)`, no UIKit** anywhere in the repo today.
The app is macOS 14+ only (`Anglesite` DevID + `AnglesiteMAS` sandboxed MAS).

---

## 2. What Cloudflare Sandbox actually gives us

Sources: [Sandbox SDK overview](https://developers.cloudflare.com/sandbox/),
[lifecycle](https://developers.cloudflare.com/sandbox/concepts/sandboxes/),
[background processes](https://developers.cloudflare.com/sandbox/guides/background-processes/),
[ports/preview URLs](https://developers.cloudflare.com/sandbox/api/ports/),
[containers architecture](https://developers.cloudflare.com/containers/platform-details/architecture/),
[pricing](https://developers.cloudflare.com/workers/platform/pricing/).

- **What it is:** a `@cloudflare/sandbox` library + a Worker. `getSandbox(env.Sandbox, id)`
  returns a handle backed by a **Durable Object** wrapping a **Cloudflare Container**
  (full Linux, Node + Python + tooling preinstalled). The container starts lazily on
  first op.
- **Run a dev server:** `sandbox.startProcess("npm run dev -- --port 8080", { cwd })`
  runs it non-blocking (survives the HTTP response); `waitForPort(8080, {timeout})`
  blocks until it's actually listening. Exactly the shape of our `AstroDevServer`
  ready-probe, but server-side.
- **Reach it from a client:** `sandbox.exposePort(port, { hostname })` returns a
  **preview URL** `https://<port>-sandbox-<id>-<token>.<your-domain>`. A Worker calls
  `proxyToSandbox(request, env)` to route those hostnames into the right container.
  **HTTP *and* WebSocket upgrades are proxied** — so Astro/Vite **HMR works** through
  the preview URL.
- **File ops:** `writeFile`/`readFile`/`exec` over the SDK.
- **Lifecycle — the load-bearing constraint:** containers go **idle after
  `sleepAfter` (default 10m) of no requests, and *all disk is ephemeral***. On the
  next request a **fresh container** starts from the image — *previous state is lost*.
  `keepAlive: true` prevents idle (30s heartbeats) but costs money continuously.
  Persistence options: **snapshots** ("coming soon"), or **FUSE-mount R2** (no
  SSD-like perf). (`containers/architecture` §Persistent disk.)
- **Preview-URL DNS caveat:** preview URLs need a **custom domain with wildcard
  DNS**; `*.workers.dev` is **not** supported (no wildcard). For dev, the **Tunnels
  API** gives `*.trycloudflare.com` without DNS setup.
- **Pricing:** included in the **$5/mo Workers Paid** plan (25 GiB-hr memory, 375
  vCPU-min, 200 GB-hr disk/month included; overages metered). CPU billed on *active*
  use as of 2025-11-21. Charges stop when the container sleeps.

---

## 3. The three hard problems (in priority order)

### 3.1 The filesystem is the source of truth — and the sandbox disk is ephemeral

This is the crux and it collides head-on with a core product rule. A site lives at
`~/Sites/<name>/` on the Mac and *must remain editable outside the app*. A sandbox
container:

- has a **throwaway disk** that resets on every idle/sleep (every ~10 min idle), and
- is **not** the user's local `~/Sites/<name>/`.

So "run `astro dev` in a sandbox" implicitly means **the site's files have to live
somewhere durable that the sandbox hydrates from and writes back to.** Options:

| Option | Source-of-truth | Notes |
|---|---|---|
| **A. Git is the source of truth** | a Git remote (the site already deploys via Cloudflare; many sites are already in a repo) | sandbox `git clone` on start, edits commit/push, local app pulls. Clean, durable, audit trail; matches "owners can use Claude Code CLI." Latency on cold start = clone time. |
| **B. R2 bucket per site** | R2 object store | sandbox syncs R2↔disk (or FUSE-mounts). App reads/writes R2. Adds an R2 sync layer to own. |
| **C. App stays the source of truth, streams files** | the *local* device | only works where the app has a real filesystem (macOS). On iOS there's no `~/Sites` — defeats the purpose. |

**Decided → (A) Git** (OPEN-1). It's already adjacent to the deploy flow and
preserves the "editable outside the app" guarantee via the repo. Per OPEN-2 this is
*remote-everywhere*: there is no local-FS-primary fallback in the end state, so the
"source of truth" is the **repo**, not a local `~/Sites` working tree (see the
reframing note at the top). **Follow-up Q-A (§7):** sites without a Git remote need a
bootstrap "create + push a repo" step.

### 3.2 The MCP edit pipeline is stdio-coupled

`MCPClient` speaks JSON-RPC over the subprocess's **stdin/stdout**, and the
`apply_edit` round-trip (`MCPApplyEditRouter`, `AnglesiteBridge`) writes to the
**local** site dir via `ANGLESITE_PROJECT_ROOT`. If the files live in the sandbox,
the **MCP server must run in the sandbox too** (same container, next to the files)
and the app must talk to it over **HTTP/WebSocket through a preview URL** instead of
stdio. The plugin already ships an MCP server (`server/index.mjs`); the question is
whether it supports (or can add) an HTTP/SSE transport. Per `CLAUDE.md`, **the
plugin is the source of truth for the MCP message schema** — so a streamable-HTTP
transport is a **paired plugin PR**, not an app-only change.

### 3.3 Preview URL reachability + auth + multi-tenancy

- **Decided → per-session Tunnel** (OPEN-5a), so the wildcard-DNS custom-domain
  requirement is sidestepped entirely — no per-user Cloudflare *domain* needed (the
  user still needs an account/token for compute, OPEN-4).
- **Decided → per-session bearer token** (OPEN-3): preview URLs are otherwise
  effectively public (the hostname token is for *routing*, not *authz*), so the proxy
  Worker validates an app-minted session token on every request. **Follow-up Q-C
  (§7):** tunnel + token must share a lifetime.
- One container **per site per user** (`getSandbox` id scoped to user+site, per the
  docs' "scope IDs to a single user" guidance).

---

## 4. Where the seam should be (it is *not* `SupervisorBackend`)

Tempting to add a `RemoteBackend: SupervisorBackend` next to `InProcessBackend`. **It
doesn't fit:** `SupervisorBackend`'s contract is "a local pid with stdout/stderr
pipes and a stdin FileHandle" — a sandbox exposes an *HTTP/WS preview URL and an SDK*,
not pipes (`stdinHandle` would return `nil`, stdout-scraping for the ready URL
disappears, etc.). Forcing it through that protocol fights the abstraction.

The right seam is **one level up, at `PreviewSession`**. Today `PreviewSession`
*is* the thing that "owns the live preview of one site." Extract a protocol:

```
protocol SiteRuntime: Sendable {
    func start(siteID:siteDirectory:) async        // or (siteID:gitRef:) for remote
    func stop() async
    func observe() -> AsyncStream<State>            // .ready(url:) etc. — unchanged
    var mcpEndpoint: MCPEndpoint { get }            // stdio (local) | http(url) (remote)
}
```

- `LocalSiteRuntime` = today's `PreviewSession`, verbatim (macOS).
- `RemoteSiteRuntime` = drives a sandbox via the Worker's control API: ensure
  container, hydrate files (§3.1), `startProcess("astro dev")`, `exposePort`, return
  the preview `url`. `MCPClient` grows an **HTTP/WS transport** alongside stdio (§3.2).

`PreviewView` already only needs a `URL` + an `EditRouter` — it doesn't care whether
the URL is `http://localhost:4321` or `https://4321-sandbox-….dev`. That's the part
that's *already* portable.

---

## 5. The iOS app is a separate, thinner shell

Even with a remote dev server, today's `AnglesiteApp` won't `#if os(iOS)` into
existence — it's AppKit-bound (`NSViewRepresentable`, `NSWindow`-style scenes,
`Process`, Keychain `kSecAttrAccessible…ThisDeviceOnly`, security-scoped bookmarks,
Sparkle, `gh`). An iOS target is a **new thin client**:

- SwiftUI + **`WKWebView` via `UIViewRepresentable`** pointed at the preview URL
  (reuse `AnglesiteBridge`'s JS overlay + `AnglesiteScriptHandler` — those are
  WebKit-level, not AppKit).
- **No** `ProcessSupervisor` / `NodeRuntime` / `InProcessBackend` / local FS.
- Edits over the remote **MCP-HTTP** endpoint (§3.2).
- Deploy: trigger `wrangler deploy` **in the sandbox** (it already runs server-side
  fine), not on-device.

So the shared-code story is roughly: `AnglesiteBridge` (WebKit overlay) and the new
`SiteRuntime`/remote-MCP layer are shared; everything `Process`/Node/AppKit is
macOS-only.

---

## 6. Proposed phasing (each phase independently useful)

1. **Spike (throwaway):** stand up a minimal Worker + `@cloudflare/sandbox`, `git
   clone` a real Anglesite site, `startProcess("npm ci && astro dev")`,
   `exposePort`, and load the preview URL **in a desktop browser**. Confirm: (a)
   `npm ci` + `astro dev` cold-start time, (b) **HMR over the preview-URL
   WebSocket**, (c) `pre-deploy-check` + `wrangler deploy` work in-container. Decide
   §3.1 (Git vs R2) from real cold-start numbers. *No app changes.*
2. **Plugin PR:** add an **HTTP/SSE (streamable-HTTP) transport** to the plugin's
   MCP server so `apply_edit` can round-trip without stdio. Tagged plugin release.
3. **App refactor (macOS, no behavior change):** extract `SiteRuntime` from
   `PreviewSession`; today's path becomes a *transitional* `LocalSiteRuntime`. Add an
   HTTP/WS transport to `MCPClient` behind the existing actor API. Pure refactor, full
   suite stays green.
4. **`RemoteSiteRuntime` (macOS):** build the full remote loop — ensure container,
   tunnel + bearer token, `git clone`/`npm ci`/`astro dev`, `exposePort` — and make
   it the macOS default. Proves the whole thing on a platform we can still debug
   locally, then **remove `LocalSiteRuntime` + embedded Node** (OPEN-2 Replace).
   Reframe the `CLAUDE.md` source-of-truth rule here.
5. **iOS target:** new thin SwiftUI/UIKit client reusing `AnglesiteBridge` +
   `SiteRuntime` (remote-only — the only runtime that exists by now).

---

## 7. Decisions — resolved 2026-05-30

All five OPEN items are settled; the table at the top of this doc is the canonical
record. Restated with rationale:

- **OPEN-1 → Git remote.** The sandbox `git clone`s a site's repo on start, runs
  `npm ci` + `astro dev`, and pushes edits back. The repo is the source of truth.
- **OPEN-2 → Replace (remote everywhere).** No `LocalSiteRuntime` in the end state;
  the embedded Node / `Process`-spawn stack is removed once `RemoteSiteRuntime` is
  proven. Single code path, no vendored Node, but requires network + a Cloudflare
  account on every platform. See the "Consequence of #2" note at the top re: the
  `CLAUDE.md` source-of-truth reframing.
- **OPEN-3 → Per-session bearer token.** The app mints a session token; the proxy
  Worker validates it on every request (injected into the `WKWebView` via header or
  signed cookie). Self-contained, identical on macOS/iOS, no Zero Trust dependency.
- **OPEN-4 → Per-user BYO token.** Reuse the Keychain `CLOUDFLARE_API_TOKEN` already
  collected for `wrangler deploy`. Each user pays their own container usage; no cost
  to Anglesite. Onboarding cost: a Workers Paid plan.
- **OPEN-5a → Per-session Tunnel.** Sidesteps the wildcard-DNS / per-user-domain
  requirement entirely (a domain on Cloudflare would otherwise be a steep ask for
  casual/iOS users). The bearer token (#3) is the security boundary, not DNS.
- **OPEN-5b → Snapshots when available.** Target Cloudflare's "coming soon" container
  snapshots to restore disk and skip `npm ci` on re-entry; ship the explicit
  "warming…" `PreviewSession.State` as the fallback until snapshots are GA.

### New questions these answers raise (for the plan, not blockers)

- **Q-A — Repo bootstrap for non-Git sites.** OPEN-1 assumes every site has a Git
  remote. Sites created in-app may not. The plan needs a "create + push a repo"
  onboarding step (likely via the user's token / `gh` equivalent) before remote
  preview can work.
- **Q-B — Edit→push→reload loop latency.** With Git as truth, an `apply_edit` is
  write→commit→push in-container; HMR picks up the in-container file write
  immediately, but cross-device convergence (another client, or the macOS pull) is
  push-bound. Confirm the in-container write is what HMR watches (it is) so edits
  feel instant locally regardless of push timing.
- **Q-C — Tunnel lifecycle vs. session token.** Per-session tunnel URL + per-session
  bearer token should share a lifetime; define who tears down the tunnel on
  window/tab close and on idle.

---

## 8. One-paragraph recommendation

It's viable and the abstraction boundary is in a good place — `PreviewView` already
only wants a URL, and `PreviewSession` is the natural `SiteRuntime` seam. The work is
**not** in spawning; it's in (1) making a remote, ephemeral disk coexist with the
source-of-truth rule — **decided: Git is the durable substrate** and, per OPEN-2,
the source of truth outright (remote-everywhere), (2) moving the **MCP edit pipeline
off stdio onto HTTP/WS** (a paired plugin change), and (3) building a **new thin iOS
client** since the current shell is AppKit-bound. With the decisions settled, the
**Phase 1 Worker spike** is now about de-risking execution (cold-start time, HMR over
the tunnel, snapshot availability) rather than choosing a substrate.
