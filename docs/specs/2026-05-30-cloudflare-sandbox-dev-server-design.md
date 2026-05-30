# Cloudflare Sandbox dev server (toward Anglesite on iOS) — Investigation / Design

> **Status:** investigation only. No implementation committed. This captures the
> findings of the "run the dev server in a Cloudflare Sandbox so Anglesite can run
> on iOS" spike and proposes a phased path. Decisions marked **OPEN** below need an
> owner sign-off before any `…-plan.md` is written.

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

**Recommendation:** lean toward **(A) Git** as the durable substrate for the
*remote/iOS* story, because it's already adjacent to the deploy flow and preserves
the "editable outside the app" guarantee. On macOS the **local FS stays primary**;
remote is an opt-in mode, not a replacement. **OPEN: pick A vs B.**

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

- Need a Cloudflare zone with **wildcard DNS** for stable preview URLs (or Tunnels
  for dev). We already collect a `CLOUDFLARE_API_TOKEN`.
- Preview URLs are effectively **public** unless gated (token in the hostname is for
  *routing*, not *authz*). A site mid-edit shouldn't be world-readable → put the
  proxy Worker behind **Cloudflare Access** or a per-session bearer token.
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
   `PreviewSession`; today's path becomes `LocalSiteRuntime`. Add an HTTP transport
   to `MCPClient` behind the existing actor API. Pure refactor, full suite stays
   green.
4. **`RemoteSiteRuntime` (macOS, opt-in):** a "Preview on Cloudflare" mode behind a
   flag — proves the whole remote loop on a platform we can still debug locally.
5. **iOS target:** new thin SwiftUI/UIKit client reusing `AnglesiteBridge` +
   `SiteRuntime` (remote-only).

---

## 7. Open decisions (need sign-off before a `…-plan.md`)

- **OPEN-1 — Durable substrate:** Git remote (§3.1-A) vs R2 (§3.1-B) as the
  source-of-truth the sandbox hydrates from. Affects everything downstream.
- **OPEN-2 — Does remote *replace* or *augment* local?** Recommendation: augment.
  macOS keeps the local subprocess path; remote is opt-in and the only path on iOS.
  Preserves the "editable outside the app" rule on the platform that has a real FS.
- **OPEN-3 — Preview-URL authz:** Cloudflare Access vs per-session bearer token vs
  Tunnels-for-dev-only. Preview URLs are otherwise effectively public.
- **OPEN-4 — Who pays / whose account?** Per-user BYO Cloudflare token (we already
  collect one) vs an Anglesite-operated account with metered cost. Containers bill on
  active use; `keepAlive` is continuous cost.
- **OPEN-5 — Cold-start UX:** `npm ci` + first `astro dev` in a fresh container is
  not instant, and idle eviction (~10 min) means re-paying it. Need a "warming…"
  state and possibly a snapshot/keepAlive strategy.

---

## 8. One-paragraph recommendation

It's viable and the abstraction boundary is in a good place — `PreviewView` already
only wants a URL, and `PreviewSession` is the natural `SiteRuntime` seam. The work is
**not** in spawning; it's in (1) making a remote, ephemeral disk coexist with the
"filesystem is the source of truth" rule (favor **Git** as the durable substrate),
(2) moving the **MCP edit pipeline off stdio onto HTTP/WS** (a paired plugin change),
and (3) building a **new thin iOS client** since the current shell is AppKit-bound.
Recommend starting with the **throwaway Worker spike (Phase 1)** to get real
cold-start / HMR numbers before committing to OPEN-1.
