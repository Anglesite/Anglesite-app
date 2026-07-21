# Local `wrangler dev` runtime — design

**Issue:** [#708](https://github.com/Anglesite/Anglesite-app/issues/708) (last of its three prerequisites — the other two shipped in PR #834)
**Governing spec:** [`docs/superpowers/specs/2026-07-13-workers-local-debugging-design.md`](2026-07-13-workers-local-debugging-design.md) §7 ("Local runtime (700a)")
**Date:** 2026-07-20
**Status:** Approved

## 1. Problem

A site's Cloudflare Worker composes `@dwk/workers` packages (webmention, indieauth, micropub, etc.) behind the site's static assets. Today the only way to see that Worker run at all is a real Cloudflare deploy — there is no local dev/debug path. This design adds a local `wrangler dev --local` (Miniflare-backed, no real Cloudflare account calls) process inside `LocalContainerSiteRuntime`, as a third guest process alongside the existing `astro dev` + MCP sidecar, so a site's active workers can be exercised entirely offline before ever deploying.

## 2. Scope

**In scope:** starting/stopping a local `wrangler dev` process tied to a site's currently-active worker set, computed once when a site's preview session opens; a real, generic, crash-restart-capable guest-process supervisor (not a one-off for this feature); the proxied URL reaching `LocalContainerSiteRuntime`'s public state.

**Out of scope (explicitly deferred, not silently missing):**
- **Live restart on toggle.** The design doc's "toggling a worker in the Workers tab restarts the local session" requirement has no real caller yet — the Workers tab (#700c) doesn't exist. This slice builds the underlying `updateActiveWorkers(_:)` capability and tests it directly, but `start()` is its only caller. #700c becomes the second caller later with no further runtime-side work needed.
- **Retrofitting `astro`/`mcp` onto the new crash-restart supervisor.** They stay on the existing `runDetached` fire-and-forget path. The supervisor's API is designed generically so a future PR *can* retrofit them, but doing so here would be an unrelated drive-by change (CONTRIBUTING.md: focused PRs).
- **A UI status indicator for wrangler-dev's running/restarting/failed state.** There's no Workers tab to show it in yet. The state is still exposed as an `AsyncStream` (see §5) so a future UI doesn't need retrofitting, but nothing consumes it in this PR beyond driving restart decisions and debug-pane log lines.
- **Component-tied worker detection at session-open time** — see the accepted limitation in §6.

## 3. Making `wrangler` available inside the container

`wrangler` is not a dependency anywhere in `Resources/Template/package.json` today, and the container image's Dockerfile has no explicit `npm install -g wrangler` either — but the image already bakes a full `npm ci` (not `--omit=dev`) of whatever the template's `package.json`/`package-lock.json` declare, via the same pre-baked-`node_modules`-tarball path `astro`/`tsx`/etc. already ride. So: **add `wrangler` as a new `devDependency` in `Resources/Template/package.json`.** No Dockerfile change, no paired sidecar PR (template changes are app-only per CLAUDE.md). The existing `anglesite-hydrate` step picks it up automatically the next time the vendored image is rebuilt.

## 4. Local-only `wrangler.toml`

`wrangler dev --local` needs a `wrangler.toml`, but the site's real one lives in the git-tracked `Source/wrangler.toml` — a transient local-dev session must never dirty that file, and per explicit product decision, **local dev must work fully before the user has ever deployed**, reflecting whatever worker toggles are active *right now*, not whatever was last deployed.

Resolution: generate an ephemeral, git-ignored `wrangler.toml` variant inside the guest on every wrangler-dev (re)start, via the existing `WorkerComposition.generateWranglerToml(workers:)` — with no real resource IDs, since Miniflare creates local-persisted D1/KV/R2 stores automatically for declared bindings in `--local` mode. `wrangler dev --local --config <ephemeral-path> --port 8787` points at it. The exact ephemeral path (e.g. a location under `/workspace/site/.anglesite-local/`) and its `.gitignore` entry are plan-level detail, not a design fork.

## 5. Type and protocol surface

Three additive changes, chosen to avoid breaking any existing conformer or call site:

- **`LocalContainerSession`** gains `workersDevURL: URL? = nil`. Every existing construction in tests/production uses keyword args, so this is fully source-compatible.
- **`SiteRuntimeState.ready`** gains the same `workersDevURL: URL? = nil` as a new associated value — additive per the governing spec's own architecture note ("extending `SiteRuntimeState` rather than changing the `SiteRuntime` protocol's shape"). This *does* touch every `case .ready(let siteID, let url)`-shaped pattern match across the app and test suites (Swift requires updating the pattern itself, not just construction sites) — the exact enumeration of those call sites is plan-level work, not a design decision, since there's no ambiguity in what needs to happen at each one (add the new binding or ignore it).
- **`LocalContainerControl` protocol** gains two new methods, called only *after* the main `start()` has already succeeded — a second, independent lifecycle nested inside the container's own, not part of boot:
  ```swift
  func startWorkersDev(siteID: String, workers: [WorkerDescriptor], onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> URL
  func stopWorkersDev(siteID: String) async throws
  ```
  `startWorkersDev` writes the ephemeral `wrangler.toml` (§4), launches `wrangler dev --local` as a *supervised* guest process (§6), wires a fourth `VsockTCPProxy` the same way `previewProxy`/`mcpProxy` already work, and returns the proxied host URL. `stopWorkersDev` tears down that one process + its proxy, independent of astro/mcp.

Since these two methods live on the public `LocalContainerControl` protocol (not the internal `runDetached`/`exec` helpers), only `ContainerizationControl` (the real conformer) and `FakeLocalContainerControl` (the test double) need them — no existing test that never calls them is affected.

## 6. Guest-process supervisor (`GuestProcessSupervisor`)

Lives in `Sources/AnglesiteContainer/` (needs Apple's Containerization types — `LinuxContainer`/`LinuxProcess` — which the Linux-portable `AnglesiteCore` target can't import). Reuses `RestartPolicy`/`ProcessExitReason` from `AnglesiteCore/SupervisorBackend.swift` directly rather than redefining them — same enum, same semantics as the existing host-process supervisor (`InProcessBackend`), just driving a guest `LinuxProcess` instead of a host `Process`.

**Mechanics**, mirroring `InProcessBackend.superviseLoop`'s existing shape:
1. `start()` execs and starts the guest process, then spawns a detached background `Task` that loops on `proc.wait()`.
2. When `wait()` returns: if the exit was an intentional `stop()` (a flag set before killing it), the loop exits cleanly, no restart. Otherwise, `RestartPolicy` is consulted exactly like the host-side version — `.onCrash(maxAttempts:baseBackoff:)` backs off, re-execs a fresh process, and gives up (logging a stderr line into the debug pane — "logs are sacred") once attempts are exhausted. Default policy mirrors `AstroDevServer`'s own restart-on-crash default (`maxAttempts: 3, baseBackoff: 0.5`) for consistency between the two dev-process kinds sharing a container.
3. **State is exposed as an `AsyncStream`, mirroring `SiteRuntime.observe()`'s pattern** (`running` / `restarting(attempt:)` / `stopped` / `failed(reason:)`), even though nothing consumes it in this PR — so a future debug-panel status indicator doesn't need the supervisor retrofitted later.

**Ownership:** `ContainerizationControl.startWorkersDev(...)` constructs one supervisor per site, stored in `LiveContainers` alongside the existing `containers`/`proxies` dictionaries. `LiveContainers.teardown(siteID:)` calls the supervisor's `stop()` *before* `container.stop()`, so its background loop can't try to relaunch a process into a container that's already going down.

**Designed generically now, used narrowly:** the API doesn't assume anything wrangler-dev-specific (argv, environment, restart policy are all parameters) — a future PR *could* retrofit `astro`/`mcp` onto it, but that retrofit is explicitly out of scope here (§2).

## 7. Activation wiring

`LocalContainerSiteRuntime.start()` computes the effective active-worker set *internally* — no `SiteRuntime` protocol change. It loads `SiteConfigStore` from the site's `Config/` directory (derived from the package layout the same way other call sites already do), does a live catalog fetch with cache-fallback (matching `DeployModel`'s GUI-path precedent — a live fetch, not the headless path's cached-only read, since this is a GUI session opening and freshest data is available), and runs it through the same `WorkerActivation.effectiveActiveIDs` / `activeDescriptors` pipeline `DeployModel` already uses. If the resulting set is non-empty, `startWorkersDev` is called after the container is otherwise ready; if empty, nothing starts (matching the governing spec's "started on demand, not unconditionally" requirement).

The runtime also gains a `updateActiveWorkers(_:)` method with the same start/stop/restart logic, built and tested directly — but `start()` is its only caller in this PR (§2).

**Known, accepted limitation:** component-tied worker detection needs a populated `SiteGraphExplorerSnapshot`, which likely isn't scanned yet the moment a site window first opens (it's populated lazily elsewhere, e.g. by the Graph Explorer tab). A **settings-activated** worker (toggled on in Settings) reliably starts its local wrangler-dev at session open; a **component-tied** worker might not, if the graph hasn't populated in time — and, combined with no live-toggle-restart wiring yet, might not start at all during that session. This mirrors the existing accepted "never invents, may under-report" bias `WorkerActivation.effectiveActiveIDs` already documents for headless deploys, surfacing in a new place. Explicitly accepted as a thin-slice tradeoff, not something this PR solves (e.g. by triggering a graph scan as part of `start()`).

## 8. Container-side details

Guest port: wrangler's own conventional local-dev port, `8787`. Proxied via a fourth `VsockTCPProxy`, exactly like the existing preview/mcp proxies (`LiveContainers.teardown` already iterates its `proxies` array generically — no teardown-path change needed for a third entry). Output streams into the same `LogCenter` source the container's other processes already use, with its own line-label prefix so it's visually distinguishable in the debug pane, matching the existing `[astro]`/`[mcp]` convention.

## 9. Testing

- **Unit:** `FakeLocalContainerControl` gains the two new methods (mirroring its existing `exec`-call-recording shape) for `LocalContainerSiteRuntimeTests` to drive — new cases: wrangler-dev starts when the effective set is non-empty, doesn't start when empty, `.ready`'s `workersDevURL` populates once available, teardown calls `stopWorkersDev`.
- **`GuestProcessSupervisor`:** its own dedicated unit-test suite covering the restart-policy state machine (crash → restart → give-up, intentional stop suppresses restart), against a fake/injectable process-launch seam — exact shape is plan-level detail, following this container target's existing test-double conventions.
- **End-to-end:** a new case in the existing `ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1`-gated `ContainerizationControlTests` suite — boot with an active worker, assert the workers-dev URL answers HTTP. Per the governing spec's own §9 testing note.
- **Human-run verification gate:** `scripts/run-container-probe.sh` gains a third subcommand (`workers-dev`), mirroring the existing `boot` subcommand's HTTP-poll pattern — this is how a human, not CI, verifies the new guest process actually boots and is reachable (CI can never carry the virtualization entitlement `swift test` would need).

## 10. Open items carried into the implementation plan (not design forks — mechanical detail)

- Exact ephemeral `wrangler.toml` path and its `.gitignore` entry.
- Every `.ready(siteID:url:)` pattern-match call site that needs updating for the new associated value.
- The exact existing log-line-prefixing mechanism (`runDetached`'s `label:` param vs. elsewhere) to mirror for wrangler-dev's own prefix.
- `LocalContainerSiteRuntime`'s exact derivation of a site's `Config/` directory from its package layout (reuse an existing `AnglesiteSiteModel` helper rather than hand-rolling path arithmetic).
- The `GuestProcessSupervisor` test seam over `LinuxContainer.exec`.
