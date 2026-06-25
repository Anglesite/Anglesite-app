# `LocalContainerSiteRuntime` (#69) — design

> **Status:** approved design, 2026-06-25. Part of the containerization epic (#59); the macOS
> production runtime. Symmetric twin of `RemoteSandboxSiteRuntime` (#66, landed via #315).
> Supersedes the "DevID-only / Cloudflare-on-MAS" framing of the #60 sub-spike — see
> [`docs/specs/2026-06-09-containerization-mas-subspike-notes.md`](../../specs/2026-06-09-containerization-mas-subspike-notes.md)
> §"Wall 3 resolved".

## 0. Summary

`LocalContainerSiteRuntime` is the **local macOS runtime**: it runs a site's `astro dev` + the
app-owned Node MCP sidecar inside an Apple-Containerization Linux VM, hydrated from the site's
`Source/` git repo, and exposes the preview + MCP endpoints to the host over a vsock→TCP proxy.
It is the near-native, offline, zero-marginal-cost counterpart to the remote Cloudflare path
(`RemoteSandboxSiteRuntime`, #66), which stays the **iOS-only** runtime.

Because Anglesite targets macOS 27+, every Mac it runs on is Apple Silicon, so this runtime is
available on **all** Macs — DevID *and* MAS — gated only on the clearable, precedented
`com.apple.security.virtualization` entitlement (Wall 2). Intel Macs and iOS fall back to the
remote runtime, exactly as for macOS < 26.

### What this design deliberately is *not*

- **Not** a repo push-back / bidirectional sync mechanism. This pass is **boot → hydrate-from-repo
  → preview → MCP → lifecycle**. Committing container edits back to `Source/` is the #72 §8
  reconciliation's job (see the package-model design §8) and a follow-up. First cut hydrates
  *from* the repo only.
- **Not** a MAS-shipping change. We link the new code into the **DevID** target now (local dev,
  where the entitlement is available for development) and defer MAS linking until Apple grants the
  virtualization entitlement for distribution.

## 1. Context & constraints

### 1.1 The entitlement gate

The #60 binary spike proved Apple Containerization is **unrunnable without
`com.apple.security.virtualization`** — the process is SIGKILL'd at launch before `main()` runs.
That entitlement is *restricted*: it requires Apple approval + a development/distribution
provisioning profile. Consequences:

- **Local development works today** (DevID, development provisioning profile with the
  entitlement). The author can build, run, and GUI-verify the full runtime on their machine.
- **CI cannot run it** — GitHub's `macos-15` runners have neither the entitlement nor (necessarily)
  Apple Silicon. Anything that *executes* the framework must therefore be excluded from the
  `swift test` flow.
- **Distribution is blocked** until Apple grants the entitlement (clearable: the shipping
  sandboxed-MAS app `try-containers/Containers` got it granted as an indie).

### 1.2 The networking model (Wall 3 resolved)

Anglesite does **not** need a routable per-container IP (the only thing that needed
`com.apple.vm.networking`). It needs a URL `WKWebView` can load and an MCP HTTP endpoint. Both are
delivered with `com.apple.security.virtualization` alone:

- **Outbound (guest → internet):** `NATInterface` → `VZNATNetworkDeviceAttachment`.
- **Inbound (host → guest port):** **vsock** — `LinuxContainer.dialVsock(port:)` returns a
  `FileHandle` to a guest port; a host-side proxy splices `127.0.0.1:<port>` ↔ that handle.

`VZVirtioSocketDevice` + `VZNATNetworkDeviceAttachment` make this **Apple Silicon only**.

### 1.3 The heavy native dependency

`apple/containerization` declares `platforms: [.macOS("15.0")]`, requires the **Swift 6.2**
toolchain, and pulls in Swift NIO, gRPC, Protobuf, and native compression libs. It compiles on the
author's Xcode-27 machine but would weigh down — and possibly break — the `swift test` flow on
CI's older runners, where it can't execute anyway. So the framework-touching code must live in a
target CI does not compile.

## 2. Architecture

Three pieces, mirroring the #315 split. **The actor, the control-protocol seam, the vsock proxy,
and the capability gate all live in `AnglesiteCore` and are CI-tested with fakes. Only the
concrete `Containerization`-importing conformer + the vendored image live in a new app-linked
target CI never compiles.**

```
AnglesiteCore (CI-tested, no native dep)          AnglesiteContainer (app-linked, not CI-compiled)
┌──────────────────────────────────────┐          ┌──────────────────────────────────────────────┐
│ protocol LocalContainerControl        │◀─────────│ struct ContainerizationControl                 │
│ struct   LocalContainerSession        │ conforms │   import Containerization / ContainerizationOCI│
│ enum     LocalContainerError          │          │   - import bundled OCI layout → ImageStore     │
│ actor    LocalContainerSiteRuntime    │          │   - LinuxContainer + VZNATNetworkDeviceAttach. │
│ struct   VsockTCPProxy (dialer seam)  │          │   - git clone Source/ repo into guest          │
│ enum     LocalContainerSupport        │          │   - start astro dev + Node MCP sidecar         │
│ FakeLocalContainerControl (tests)     │          │   - VsockTCPProxy(dialer: container.dialVsock) │
└──────────────────────────────────────┘          │   + Resources/container-image/ (Bundle.module) │
                                                   └──────────────────────────────────────────────┘
```

### 2.1 Seam — `AnglesiteCore`

Symmetric with `SandboxControlClient` / `SandboxSession` / `SandboxControlError`. No
`Containerization` types cross this boundary.

```swift
/// Host-reachable endpoints a started local container exposes. Both are 127.0.0.1 URLs on
/// OS-assigned ports, delivered by the host-side vsock→TCP proxy.
public struct LocalContainerSession: Sendable, Equatable {
    public let previewURL: URL   // http://127.0.0.1:<port> → guest astro (vsock 4321)
    public let mcpURL: URL       // http://127.0.0.1:<port> → guest MCP sidecar (vsock 4399)
}

public enum LocalContainerError: Error, Equatable {
    case virtualizationUnavailable   // no entitlement / not Apple Silicon / macOS < 26
    case imageUnavailable(String)    // bundled OCI layout missing or failed to import
    case bootFailed(String)          // VM/container failed to boot
    case cloneFailed(String)         // git clone of Source/ into the guest failed
}

/// Typed wrapper over "boot a container, hydrate it from a repo, start the guest processes, and
/// return host-reachable endpoints." `ContainerizationControl` is the production conformer;
/// `FakeLocalContainerControl` backs the tests. Mirrors `SandboxControlClient`.
public protocol LocalContainerControl: Sendable {
    func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession
    func stop(siteID: String) async throws
}
```

`LocalContainerSiteRuntime: SiteRuntime` is a near-verbatim copy of `RemoteSandboxSiteRuntime`'s
actor: generation-guarded `teardown → .starting → control.start → connect(mcpClient, mcpURL) →
.ready(url: previewURL) / .failed`, multi-observer `observe()`, `stop()` → `.idle`. It spawns
nothing itself. `siteDirectory` (from `SiteRuntime.start`) is the package's `Source/` directory; the
runtime passes `file://<siteDirectory>` as `sourceRepo` and `HEAD` (or a configured ref) to the
control — keeping git the source of truth (#72): the container working copy is hydrated from the
repo, not from the app's tree.

`friendlyMessage(for:)` maps each `LocalContainerError` to an owner-facing string (e.g.
`.virtualizationUnavailable` → "This Mac can't run local previews — using the remote runtime
instead."), exactly as the remote runtime does for `SandboxControlError`.

### 2.2 `VsockTCPProxy` — the isolation linchpin

The proxy's *byte-splicing* (the bug-prone part) lives in `AnglesiteCore` and is CI-tested; only
the *dial* is framework-bound, injected as a closure:

```swift
public typealias VsockDialer = @Sendable (_ guestPort: UInt32) async throws -> FileHandle

public actor VsockTCPProxy {
    /// Binds 127.0.0.1:0 (OS-assigned port). For each accepted TCP connection, calls `dial(port)`
    /// and splices the two FileHandles bidirectionally until either side closes.
    public init(guestPort: UInt32, dial: @escaping VsockDialer) { ... }
    public func start() async throws -> URL   // returns http://127.0.0.1:<assignedPort>
    public func stop() async
}
```

- **Production** passes `dial: { port in try container.dialVsock(port: port) }`.
- **Tests** pass a loopback dialer (a `Pipe`/socketpair pair) and assert bidirectional bytes, EOF
  half-close, and teardown — no framework, no entitlement.
- Bind **port 0** and use the OS-assigned port (never fixed ports — they collide with whatever the
  user is already running).

### 2.3 Capability gate — `LocalContainerSupport`

```swift
public enum LocalContainerSupport {
    /// macOS 26+ AND arm64 AND the virtualization entitlement is present.
    public static func isAvailable(...) -> Bool
}
```

Pure function (inputs injectable for tests). Drives runtime selection; never throws.

### 2.4 Conformer — `AnglesiteContainer` (app-linked, not CI-compiled)

`ContainerizationControl: LocalContainerControl` imports `Containerization` / `ContainerizationOCI`:

1. **Image:** on first `start`, import the bundled OCI **layout** into the on-disk `ImageStore` via
   `LocalOCILayoutClient(root: bundledLayoutURL)` (idempotent — later runs find it in the content
   store). No registry, no network.
2. **Boot:** create a `LinuxContainer` from the image with `VZNATNetworkDeviceAttachment` (outbound)
   + the auto-provisioned `VZVirtioSocketDevice`.
3. **Hydrate:** `git clone <sourceRepo> <ref>` into the guest working directory (in-guest git;
   `sourceRepo` is the host `file://…/Source` path, made reachable to the guest).
4. **Run:** start `astro dev` (guest TCP 4321) and the Node MCP sidecar (guest TCP, fronted by the
   guest vsock bridge on 4399).
5. **Expose:** stand up two `VsockTCPProxy` instances (preview → 4321, MCP → 4399) with the real
   `container.dialVsock` dialer; return their `127.0.0.1` URLs as a `LocalContainerSession`.
6. **stop:** stop the proxies, stop the guest processes, stop the container/VM.

### 2.5 Guest side — the OCI image

- The #62 image is **amd64**; rebuild **arm64** for Apple Silicon.
- Add a **compiled** vsock→TCP bridge (not `socat`: too heavy, rough under `fork`) that listens on
  vsock 4321/4399 and forwards to the guest's local `astro` / MCP TCP ports — Astro and Node speak
  TCP, not vsock.
- Bake the project's runtime (Node + `astro` + the MCP sidecar) into the image so first-run needs
  no in-guest install.

### 2.6 Selection — app target

At `Sources/AnglesiteApp/PreviewModel.swift:40` (today `LocalSiteRuntime(contentGraph:)`), introduce
a small factory driven purely by capability — no feature flag:

- `LocalContainerSupport.isAvailable` (macOS 26+, arm64, virtualization entitlement present) →
  `LocalContainerSiteRuntime(control: ContainerizationControl(...))`.
- else → today's `LocalSiteRuntime` (host subprocess) on macOS, or `RemoteSandboxSiteRuntime` on
  iOS / Intel.

No flag is needed: the entitlement *is* the gate. Any build without it (every normal dev/CI build,
and any user build until distribution is approved) returns `isAvailable == false` and falls back
automatically. The container path activates only on a build signed with a profile that carries the
entitlement — i.e. the author's local dev build today, and the shipping build once approved.

## 3. Packaging & platform scoping

| Concern | Decision |
|---|---|
| Where the framework code lives | New `AnglesiteContainer` SPM target (`Sources/AnglesiteContainer`), deps `AnglesiteCore` + `.package(url: github.com/apple/containerization)`; new `.library` product. **No test target depends on it**, so `swift test` doesn't compile it. `Package.resolved` gains the NIO/gRPC/protobuf graph — the accepted cost. |
| Where the image lives | `Resources/container-image/` declared as a **resource of the `AnglesiteContainer` target**, resolved at runtime via `Bundle.module`. Gitignored; populated by a new `scripts/vendor-container-image.sh` (mirrors `scripts/vendor-node.sh`). The image is inert data (Linux rootfs + manifests) — **no Mach-O, no codesigning** (unlike the embedded Node re-sign). |
| iOS exclusion | The iOS thin client (#71) links `AnglesiteCore` only → ships `RemoteSandboxSiteRuntime`, **never** links `AnglesiteContainer` → no framework, **no image**. The 200–500 MB blob is excluded by the dependency graph, with no `#if` to maintain. |
| Which app targets link it | **DevID `Anglesite`** now (add `com.apple.security.virtualization` to its dev entitlements). **`AnglesiteMAS` deferred** until Apple grants the entitlement for distribution. |
| Bundle size | macOS-only weight, plausibly **200–500 MB** (Linux userland + Node + `node_modules`). Build-time blob, no per-user state. If too heavy later: hybrid (thin base layer bundled, rest pulled). Start simple, measure. |

## 4. Lifecycle

- **Stop-on-window-close:** each `SiteWindow` owns its runtime; closing it calls `stop()` →
  proxies down, guest processes down, VM down.
- **Idle reaping (local half of Q-C):** a simple idle timer in the runtime/control stops the
  container after N minutes with no activity. Sophisticated reaping is deferred.

## 5. Testing

| Layer | Where | Runs on CI? |
|---|---|---|
| State machine (`LocalContainerSiteRuntimeTests`, `FakeLocalContainerControl`) — transitions, supersession, teardown; clone of `RemoteSandboxSiteRuntimeTests` | `AnglesiteCoreTests` | ✅ |
| `VsockTCPProxyTests` — loopback dialer; bidirectional splice, half-close, teardown | `AnglesiteCoreTests` | ✅ |
| `LocalContainerSupport` capability gate | `AnglesiteCoreTests` | ✅ |
| `ContainerizationControl` real boot + curl preview URL | local-only, behind an env gate (e.g. `ANGLESITE_CONTAINER_E2E`, like the sharp/MCP e2e gating) | ❌ (author runs it) |
| Full preview in the running DevID app | GUI-verify | ❌ (author runs it) |

## 6. Risks & open questions

1. **Entitlement timeline.** Distribution is blocked on Apple granting
   `com.apple.security.virtualization`. Mitigated: DevID-only now; the capability gate alone means
   nothing breaks for users who lack it (they fall back). File the Apple request in parallel. If
   the MAS request is ultimately denied, the fallback is the **self-hosted notarized download**
   (DevID distribution outside the App Store), where the entitlement is grantable on the DevID
   track — so the local runtime ships either way; only the *channel* is contingent.
2. **Bundle size.** See §3. Measure the real arm64 image before deciding whether the hybrid is
   needed.
3. **In-guest git hydration of a host `file://` repo.** The guest must reach the host repo to
   clone. Resolve the exact mechanism (shared directory mount vs. a host-side git-over-vsock
   transport) during implementation; it does not change the seam.
4. **`UnixSocketRelay` / `VsockListener` access level.** `apple/containerization` has these as
   reference relay patterns; confirm public vs. internal before depending on them. `VsockTCPProxy`
   is written against the public `dialVsock` alone, so this is an optimization, not a blocker.
5. **Swift 6.2 toolchain on the conformer.** `AnglesiteContainer` needs Swift 6.2+; fine locally
   (Xcode 27), and it never builds on the older CI runner by construction.

## 7. Cross-references

- Epic: #59 · this issue: #69 · remote twin: #66 (landed via #315).
- Wall 3 resolution: [`docs/specs/2026-06-09-containerization-mas-subspike-notes.md`](../../specs/2026-06-09-containerization-mas-subspike-notes.md) §"Wall 3 resolved".
- Remote design (the symmetric reference): [`docs/specs/2026-06-23-remote-sandbox-runtime-ios-design.md`](../../specs/2026-06-23-remote-sandbox-runtime-ios-design.md).
- Git-as-source-of-truth + the package model: [`docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md`](2026-06-19-anglesite-package-model-design.md) §8.
- Seam precedents in code: `Sources/AnglesiteCore/SiteRuntime.swift`, `RemoteSandboxSiteRuntime.swift`, `SandboxControlClient.swift`, `HTTPSandboxControlClient.swift`, `LocalSiteRuntime.swift`.
