# Containerized dev server (local on macOS, Cloudflare on iOS) — Investigation / Design

> **Status:** investigation. No implementation committed. This captures the findings
> of the "run the dev server off the host process so Anglesite can run on iOS" spike
> and proposes a phased path. **Decisions resolved 2026-05-30 (two rounds) — see §0
> and §7.** Next artifact is a `…-plan.md`, gated on the Phase 0 spike (§6).

## 0. Architecture — platform-split, one container image (resolved 2026-05-30, round 2)

The dev server (and the plugin's MCP server) always run **inside a Linux container**,
never in the host app process. The *same OCI image* is executed two ways depending on
the platform's capability:

| Platform | Substrate | Reachability |
|---|---|---|
| **macOS 26+ on Apple Silicon** | **Apple Containerization** (`container` / the `containerization` Swift package) — local lightweight per-container VM | host-local: each container gets a dedicated IP → `http://<ip>:4321` directly |
| **Intel Macs · macOS < 26 · iOS/iPadOS** | **Cloudflare Sandbox** (remote container) — the fallback for anything that can't run the local VM | per-session **Cloudflare Tunnel** + **bearer token** |

This is the security/performance trade the owner asked for: capable Macs get a **local,
zero-network, zero-marginal-cost** container with full-VM isolation; everything else
(and all of iOS) gets the **remote** container. Because both run the **same image**,
`SiteRuntime` (§4) has two thin implementations over one behavior contract.

**Net simplification:** there is **no embedded-Node / host-`Process` path in the end
state at all.** The entire Phase 10.1 bundled-Node re-sign / JIT-entitlement saga
(`scripts/resign-node.sh`, `node-runtime.entitlements`, `cs.allow-jit`) becomes
**moot** — JIT runs inside the guest, not the host.

### Decisions table

| # | Decision | Choice |
|---|---|---|
| 1 | Source of truth | **Git, everywhere** — the container `git clone`s on start; edits commit/push. No VirtioFS host-share; no live local `~/Sites` working tree driven by the app. |
| 2 | Scope | **Replace** the host-subprocess path with containers. macOS-capable → local container; else → Cloudflare. |
| 2a | Local container tech | **Apple Containerization** (`container`), macOS 26+ / Apple Silicon. Same OCI image as Cloudflare. |
| 2b | Fallback | **Cloudflare Sandbox** for Intel, macOS < 26, and iOS. |
| 3 | Remote preview authz | **Per-session bearer token** (app-minted, proxy-Worker-validated). *Local containers are host-only; bearer token optional there.* |
| 4 | Account/billing | **Per-user BYO Cloudflare token** (reuse Keychain `CLOUDFLARE_API_TOKEN`) — only the *remote* path bills. The local path is free. |
| 5a | Remote URL exposure | **Per-session Cloudflare Tunnel** — no wildcard-DNS domain needed. |
| 5b | Cold-start | Skip `npm ci` via **committed/snapshotted images** (local: a pre-baked image layer; remote: Cloudflare container snapshots when GA); "warming…" UX fallback. |

### ⚠️ Load-bearing risk — verify in Phase 0 before committing the plan

**Apple Containerization may not run inside a sandboxed MAS app.** The `container`
tool is architected as a **system daemon** (`container system start`) using XPC +
`vmnet`-class networking. Embedding the `containerization` package in an
**App-Sandboxed** process is **unproven** and may require entitlements the Mac App
Store does not grant. Outcomes to design for:

- **Best case:** it works in-sandbox (or with a documented helper) → local path on
  both `Anglesite` (DevID) and `AnglesiteMAS`.
- **Likely fallback:** local path is **DevID-only**; the **MAS build always uses the
  Cloudflare path** (consistent with Intel/old-macOS fallback). MAS then never needs
  the virtualization entitlement at all.

Either way the product is shippable; the spike just decides *which* Macs get the
local fast-path. **No plan is written until Phase 0 answers this.**

### Source-of-truth reframing (applies to `CLAUDE.md`)

With Git as the source of truth on every platform, the `CLAUDE.md` rule "the
filesystem is the source of truth / the app must never be the only way to edit a
site" is **reframed to "Git is the source of truth."** The repo — clonable into
Finder/VS Code/Claude Code CLI on any machine — remains the real, externally-editable
copy, so the *spirit* holds. **Update `CLAUDE.md` when the plan lands.**

---

> **Round-1 note (superseded by §0):** the first decision round chose *Cloudflare
> everywhere* (incl. macOS). Round 2 split it: capable Macs run the container
> **locally** via Apple Containerization for cost/latency/offline reasons, with
> Cloudflare as the fallback + the iOS path. The §1–§8 body below predates round 2
> and still reads as Cloudflare-centric; §0 + §7 are canonical where they differ.

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
*is* the thing that "owns the live preview of one site." Extract a protocol with
**two container implementations** (per §0 — there is no host-subprocess impl in the
end state):

```
protocol SiteRuntime: Sendable {
    func start(siteID:gitRef:) async       // both impls hydrate from Git, run the same image
    func stop() async
    func observe() -> AsyncStream<State>   // .ready(url:) etc. — unchanged
    var mcpEndpoint: URL { get }           // HTTP/WS endpoint of the in-container MCP server
}
```

- `LocalContainerSiteRuntime` (macOS 26+/Apple Silicon) = drives **Apple
  Containerization**: pull/run the OCI image, `git clone` into it, start `astro dev`
  + the MCP server, expose the container IP. Host-local, no tunnel.
- `RemoteSandboxSiteRuntime` (Intel · macOS < 26 · iOS) = drives a **Cloudflare
  Sandbox** via the Worker control API: `getSandbox`, `git clone`,
  `startProcess("astro dev")`, tunnel + bearer token, return the preview `url`.

Both speak to the **same in-container MCP server over HTTP/WS** (§3.2), so `MCPClient`
grows one HTTP transport that serves both — **stdio goes away with the host
subprocess.** `PreviewView` already only needs a `URL` + an `EditRouter`; it doesn't
care whether the URL is a local container IP or a Cloudflare tunnel. That part is
*already* portable.

---

## 5. The iOS app is a separate, thinner shell

Even with a remote dev server, today's `AnglesiteApp` won't `#if os(iOS)` into
existence — it's AppKit-bound (`NSViewRepresentable`, `NSWindow`-style scenes,
`Process`, Keychain `kSecAttrAccessible…ThisDeviceOnly`, security-scoped bookmarks,
`gh`). An iOS target is a **new thin client**:

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

0. **⚠️ De-risking spike (gates the plan) — Apple Containerization under App
   Sandbox.** Prove whether the `containerization` Swift package can `run` a Linux
   container *from inside an App-Sandboxed (MAS) process* — or whether it needs the
   system `container` daemon / entitlements MAS won't grant. Output: a yes/no on
   "local path on MAS," which decides whether MAS ships local-or-Cloudflare (see §0
   risk). Also measure local container boot + `astro dev` time. *No app changes.*
1. **OCI image + Cloudflare spike (throwaway).** Define **one Dockerfile** (Node +
   Astro deps) used by both substrates. Stand up a minimal Worker + `@cloudflare/sandbox`
   running that image, `git clone` a real site, `startProcess("astro dev")`, tunnel,
   load the preview **in a browser**. Confirm: (a) cold-start time, (b) **HMR over the
   tunnel WebSocket**, (c) `pre-deploy-check` + `wrangler deploy` in-container, (d)
   snapshot availability. *No app changes.*
2. **Plugin PR:** add an **HTTP/SSE (streamable-HTTP) transport** to the plugin's
   MCP server so `apply_edit` round-trips without stdio. Tagged plugin release.
3. **App refactor (no behavior change):** extract `SiteRuntime` from `PreviewSession`;
   today's path becomes a *transitional* `LocalSiteRuntime` (host subprocess). Add the
   HTTP/WS transport to `MCPClient` behind the existing actor API. Pure refactor, full
   suite green.
4. **`RemoteSandboxSiteRuntime` (macOS, all-Mac fallback path first).** Build the
   Cloudflare loop — `getSandbox`, `git clone`, `astro dev`, tunnel + bearer token —
   and make it the default on Macs that can't run local. Debuggable on the desktop.
5. **`LocalContainerSiteRuntime` (macOS 26+/Apple Silicon).** Apple Containerization
   running the **same OCI image** locally; select it when capable, else fall back to
   Phase 4. Then **remove the transitional `LocalSiteRuntime` + embedded Node**
   (`scripts/resign-node.sh` et al. retire). Reframe the `CLAUDE.md` rule here.
6. **iOS target:** new thin SwiftUI/UIKit client reusing `AnglesiteBridge` +
   `RemoteSandboxSiteRuntime`.

---

## 7. Decisions — resolved 2026-05-30 (two rounds)

The **§0 table is canonical.** Round 1 settled the Cloudflare substrate; round 2
split execution by platform (local Apple Containerization on capable Macs, Cloudflare
otherwise). Rationale, restated:

- **#1 Git, everywhere.** Container `git clone`s on start; edits commit/push. One
  source-of-truth model across local + remote. (Round-1 §3.1-A, now applied to the
  local container too — no VirtioFS host-share.)
- **#2 Replace, platform-split.** No host-`Process`/embedded-Node path survives.
  macOS-capable → local container; Intel/old-macOS/iOS → Cloudflare. See §0 risk re:
  whether *MAS* counts as "capable."
- **#2a Apple Containerization** for local: same OCI image as Cloudflare, full-VM
  isolation, sub-second boot, zero network/marginal cost. macOS 26+ / Apple Silicon.
- **#2b Cloudflare Sandbox** is the universal fallback + iOS path.
- **#3 Per-session bearer token** (remote only; local containers are host-bound).
- **#4 Per-user BYO Cloudflare token** — only the *remote* path bills; local is free.
- **#5a Per-session Tunnel** — no wildcard-DNS domain onboarding (remote only).
- **#5b Pre-baked image / snapshots** to skip `npm ci`; "warming…" UX fallback.

### New questions these answers raise (for the plan, not blockers)

- **Q-0 — Containerization × App Sandbox (MAS).** The §0 load-bearing risk;
  **Phase 0** answers it.
- **Q-A — Repo bootstrap for non-Git sites.** Git-everywhere assumes every site has a
  remote. In-app-created sites may not — needs a "create + push a repo" onboarding
  step (via the user's token / `gh` equivalent) before either runtime can hydrate.
- **Q-B — Edit→reload latency.** `apply_edit` is write→commit→push in-container; HMR
  watches the in-container *write*, so local edits feel instant regardless of push
  timing. Cross-device convergence is push-bound (acceptable).
- **Q-C — Tunnel/session lifetime.** Tunnel URL + bearer token share a lifetime
  (remote); define teardown on window/tab close + idle. Local containers: define
  stop-on-window-close + idle reaping.
- **Q-D — Image distribution.** Where the OCI image comes from (built + pushed to a
  registry the user pulls, vs. Cloudflare-side build) and how local Apple
  Containerization pulls the *same* digest. Affects reproducibility + cold start.

---

## 8. One-paragraph recommendation

It's viable and the abstraction boundary is in a good place — `PreviewView` already
only wants a URL, and `PreviewSession` is the natural `SiteRuntime` seam with two
container implementations over one OCI image. The work is **not** in spawning; it's
in (1) **Git as the single source of truth** for both substrates, (2) moving the
**MCP edit pipeline off stdio onto HTTP/WS** (a paired plugin change), (3) running
the **same image** locally via Apple Containerization and remotely via Cloudflare,
and (4) a **new thin iOS client**. The single biggest unknown is **whether Apple
Containerization runs under the App Sandbox (MAS)** — so the **Phase 0 spike gates
everything**; if it fails, MAS simply uses the Cloudflare path like Intel/old-macOS,
and the product still ships. A welcome side effect of the whole direction: the
embedded-Node re-sign / JIT-entitlement complexity (Phase 10.1) **retires**.
