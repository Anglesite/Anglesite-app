# LAN-reachable local runtime — design note

**Status:** Draft
**Relates to:** #589 (UTM-VM dev/test rig), #59 (containerization epic), #64 (HTTP/Streamable MCP transport), #66/#67/#71/#342 (remote runtime + billing)

## Problem

[#589](https://github.com/Anglesite/Anglesite-app/issues/589) Phase 1 wants UTM guest VMs (macOS/Windows/Linux) to exercise `SiteRuntime` against a runtime hosted on the owner's Mac Studio, as free/fast dev-and-test infrastructure ahead of wiring every iteration through Cloudflare billing (#66).

Confirmed directly in a macOS UTM/VZ guest VM (this environment): `sysctl kern.hv_support` reports `0` — nested virtualization is unavailable. `LiveSiteRuntimeFactory.makeRuntime` (`Sources/AnglesiteApp/LiveSiteRuntimeFactory.swift:18-41`) only ever selects `LocalContainerSiteRuntime` or `UnavailableSiteRuntime` — there is no fallback path today, so any guest without nested virtualization gets a hard `UnavailableSiteRuntime` and cannot preview or edit a site at all. `RemoteSandboxSiteRuntime` exists in `AnglesiteCore` but isn't wired into the factory's selection.

## What already exists (and is reusable as-is)

- **`SiteRuntime` protocol** (`Sources/AnglesiteCore/SiteRuntime.swift:25-30`) — `start(siteID:siteDirectory:)`, `stop()`, `observe() -> AsyncStream<SiteRuntimeState>`, `var mcpClient: MCPClient`. Any new conformer only needs to satisfy this.
- **HTTP/Streamable MCP transport** (`Sources/AnglesiteCore/HTTPTransport.swift:9`, wired via `MCPClient.connect(httpEndpoint:bearerToken:urlSession:...)` at `MCPClient.swift:161-169`) is already runtime-agnostic: it takes a plain `URL` and an optional `SessionToken` bearer. Nothing about it is Cloudflare- or container-specific.
- **`RemoteSandboxSiteRuntime`** (`Sources/AnglesiteCore/RemoteSandboxSiteRuntime.swift:6`) already does the pattern we need — drive a control abstraction (`SandboxControlClient`) to get a `previewURL`/`mcpURL` pair, then `connect(mcpClient, session.mcpURL, token)`. Cloudflare specifics are isolated to `HTTPSandboxControlClient` (`Sources/AnglesiteCore/HTTPSandboxControlClient.swift`); `RemoteSandboxSiteRuntime` itself depends only on the `SandboxControlClient` protocol.
- **`PreviewView`** (`Sources/AnglesiteApp/PreviewView.swift`) loads whatever `previewURL` the runtime reports via `SiteRuntimeState.ready(siteID:, url:)` into a `WKWebView` — no vsock/tunnel assumption baked in.
- **`SessionToken`** (`Sources/AnglesiteCore/SessionToken.swift`) is already optional on the connect path — a trusted-LAN runtime can pass `nil` and skip auth, or mint a token for parity with the sandbox path.

Conclusion: no new transport or protocol work is needed. This is a thin new `SiteRuntime` conformer plus a small server-side piece to run on the Mac Studio.

## Proposed shape: `LANSiteRuntime`

A `SiteRuntime` conformer structurally like `RemoteSandboxSiteRuntime`, but against a much thinner control surface than `SandboxControlClient` (which mints Cloudflare Worker tokens and does start/stop RPCs a trusted LAN doesn't need):

```swift
actor LANSiteRuntime: SiteRuntime {
    private let host: String   // e.g. "mac-studio.local" or a configured IP, Settings-configurable
    private let previewPort: Int
    private let mcpPort: Int
    let mcpClient: MCPClient

    func start(siteID: String, siteDirectory: URL) async {
        // No remote lifecycle call — the host-side server process is assumed already running
        // and serving `siteID` (or the single site it was launched against). Construct the two
        // URLs directly and connect, exactly as RemoteSandboxSiteRuntime.start() does today:
        //   connect(mcpClient, URL(string: "http://\(host):\(mcpPort)/mcp")!, bearerToken: nil)
        // then publish .ready(siteID:, url: previewURL) via the state stream.
    }
    // stop(), observe() mirror RemoteSandboxSiteRuntime's bookkeeping.
}
```

No new proxying: the guest connects straight to `http://<mac-studio>:<port>` for both MCP and preview — no vsock, no tunnel. (`VsockTCPProxy`'s `dial`/`ProxyConnection` splice machinery in `Sources/AnglesiteCore/VsockTCPProxy.swift` is genuinely reusable if a future variant needs an app-side proxy — the vsock dependency is confined to its `VsockDialer` closure — but a plain LAN runtime doesn't need a local proxy at all, since the guest can reach the Mac Studio's TCP ports directly over the bridged/shared network.)

## Host side (Mac Studio)

Needs a small standing process that:
1. Runs the site's dev server + MCP server for a given `siteDirectory` (this can literally be today's `AstroDevServer` + `MCPClient`'s server-side counterpart, run as a normal host process — no container needed on the Mac Studio itself, since it's the trusted host, not a guest).
2. Binds MCP and preview listeners to the LAN interface instead of loopback-only.
3. Optionally checks a bearer token if we want auth parity with the sandbox path — skippable for a single-owner LAN.

This piece has no existing conformer to reuse (`AstroDevServer`/`ProcessSupervisor` currently assume the same-host loopback case) and needs its own small design pass — likely a `--bind 0.0.0.0` / `--host` flag threaded through, not a new abstraction.

## Wiring point

`LiveSiteRuntimeFactory.makeRuntime` (`Sources/AnglesiteApp/LiveSiteRuntimeFactory.swift:18-41`) needs a third branch: when `LocalContainerSupport.availability` is `.unavailable` (e.g. `kern.hv_support == 0`) **and** a LAN runtime host is configured (new Settings field, analogous to the existing "Plugin path" / "Sites root" dev overrides in Settings → Advanced), select `LANSiteRuntime` instead of falling through to `UnavailableSiteRuntime`. Absent that setting, today's behavior (hard failure) is unchanged — this is additive, dev/test-only wiring, not a change to the shipping runtime-selection policy for real users.

## Non-goals (for this note)

- Not a production runtime option — this is dev/test infra per #589, gated behind an explicit Settings override, same spirit as the existing plugin-path/sites-root dev overrides.
- Not solving auth/security for an untrusted network — LAN-only, single-owner assumption. If that assumption doesn't hold, reuse `SessionToken` bearer auth (already optional on the connect path) rather than inventing something new.
- Doesn't touch Windows/Linux guest OS specifics (#568/#569) — the guest-side client is the same Swift `MCPClient`/`WKWebView`-equivalent regardless of guest OS; only the host-side listener changes.

## Open questions before implementation

1. Does the Mac-Studio-side dev-server process need to support multiple concurrent sites (one per guest), or is one site per LAN-runtime instance acceptable for v1? (#587's "runtime inbox capture" work may want the same host-side process — worth checking for overlap before building a second one.)
2. Should `LANSiteRuntime` be a permanent `AnglesiteCore` type or a dev-only type kept out of Release builds entirely (like the Debug-only pane)? Given it's guarded behind a Settings override already, probably fine to ship the type but keep the Settings entry hidden unless a diagnostics/dev flag is set — consistent with the Debug-pane precedent (`CLAUDE.md` Phase 3 notes).
3. Confirm whether `RemoteSandboxSiteRuntime` (#66/#71/#342) is a better model to *extend* (add a `SandboxControlClient` conformer that talks to a bare LAN host instead of a Cloudflare Worker) rather than writing a new `LANSiteRuntime` type from scratch — that would keep exactly one remote-runtime code path instead of two. Leaning toward this on a closer read: `RemoteSandboxSiteRuntime` never touches Cloudflare types directly, so a `LocalLANControlClient: SandboxControlClient` that just returns a static `SandboxSession` (constructed from Settings host/port, no real start/stop RPC) may be strictly less code than a parallel `LANSiteRuntime`.
