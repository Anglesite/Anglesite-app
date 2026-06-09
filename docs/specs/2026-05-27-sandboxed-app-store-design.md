# Sandboxed Mac App Store build — embedded Node under App Sandbox

**Status:** approved — **ARCHITECTURE PIVOTED 2026-05-28** (XPC helper removed; see banner below)
**Tracks:** Phase 10 step 1 of [build-plan.md](../build-plan.md#phase-10--v2-polish) — "Mac App Store build (sandboxed)" from design doc §12 ([../../anglesite/docs/dev/mac-app-design.md](../../anglesite/docs/dev/mac-app-design.md))
**Cross-repo:** none — this is app-only; the plugin's files copy in unchanged
**Date:** 2026-05-27 (pivoted 2026-05-28)

> ## ⚠️ ARCHITECTURE PIVOT (2026-05-28) — the XPC helper is GONE
>
> The original design (everything below referencing `AnglesiteHelper`, `XPCBackend`, the XPC protocol, helper entitlements) was built on a **false premise**: that a sandboxed app can't spawn subprocesses and therefore needs an out-of-process XPC helper. Five spikes disproved the helper path and validated a far simpler one. Empirical findings (notes files dated 2026-05-27/28):
> - **Node runs under App Sandbox** (`cs.allow-jit` suffices; sub-spike B).
> - **`/usr/bin/git` is blocked** in-sandbox (xcrun shim) — but git is plugin-side Node, best-effort, and absent from MAS 10.1 with chat. No libgit2.
> - **A security-scoped grant does NOT reach a separate XPC helper** — not via bookmark resolution (6.5, fails even signed), not via fd-passing, not via `inherit` (6.6, "everything fails"). The grant is a sandbox extension **bound to the granting process**.
> - **A direct child of the grant-holding app DOES inherit the grant** for absolute-path writes — `/bin/sh` and the bundled Node both wrote throughout a user-granted folder; a never-granted folder correctly EPERM'd (6.7, decisive).
>
> **Actual architecture for MAS:** the `AnglesiteMAS` app is sandboxed and uses the **same `InProcessBackend`** as the DevID build — it spawns Node/Astro/wrangler **directly** via `Process()`. Per `SiteWindow`, the app resolves the site's persisted security-scoped bookmark and calls `startAccessingSecurityScopedResource()`, holding the grant for the window's lifetime; the spawned children inherit folder access. **No XPC helper, no `XPCBackend`, no XPC protocol.** The only MAS-specific deltas over DevID are: (1) sandbox entitlements, (2) per-`SiteWindow` security-scoped grant management, (3) the **bundled Node binary re-signed** with `cs.allow-jit` + `cs.allow-unsigned-executable-memory` + `inherit` + `app-sandbox` (required or V8 OOMs under hardened runtime), (4) chat/Sparkle/`gh` compiled out, (5) MAS signing/packaging.
>
> **Status of shipped work:** Tasks 1 (MAS target), 2 (`SupervisorBackend`), 3 (`InProcessBackend`) are KEPT. Tasks 4 (XPC protocol), 5 (helper target), 6 (`XPCBackend`) are being REVERTED — the helper bought nothing and couldn't get folder access anyway. The `SupervisorBackend` protocol stays (clean seam; `InProcessBackend` is its only impl). `SpawnSpec.workingDirectoryBookmark` is removed (no boundary to cross).
>
> Everything below this banner that describes the XPC helper is **historical** — read it for context, not as the plan. The sections updated to the new architecture are marked with "(pivoted)".

## Motivation

Anglesite v1 ships exclusively as a Developer ID `.dmg` with auto-update via Sparkle — fine for early adopters, but the Mac App Store is the discovery surface most independent owners actually browse. Design doc §10 has always called for MAS distribution at v2; Phase 9 closing is the right moment to land it because the live-edit pipeline is now stable and we know exactly what the runtime spawns.

The hard part isn't packaging or signing — it's that the App Sandbox blocks `Process()` against arbitrary binaries, and Anglesite spawns *a lot* of them: the vendored Node binary (for `astro dev` and the plugin's MCP server), `wrangler` from each site's `node_modules/.bin/`, system `git`, `/usr/bin/env`. Sandboxed apps reach those binaries through a bundled XPC service with its own (typically more permissive) entitlement set. Phase 10.1 builds that service, wires it into the existing `ProcessSupervisor` actor as a swappable backend, and ships a second Xcode target (`AnglesiteMAS`) that uses it.

The Developer ID build (`Anglesite`) is unchanged. Two builds, two architectures, one codebase.

## Scope and explicit deferrals

In Phase 10.1:

- New `AnglesiteMAS` Xcode target (sandboxed, MAS-signed) alongside existing `Anglesite` target.
- New `AnglesiteHelper` XPC service target (bundled in `AnglesiteMAS` only).
- `SupervisorBackend` protocol with `InProcessBackend` (DevID) and `XPCBackend` (MAS) impls.
- Security-scoped bookmark persistence for site folders, threaded through the XPC boundary.
- MAS-specific entitlements, `Info.plist`, and signing config.
- Smoke fixture variant that exercises the MAS build end-to-end.
- App Store submission pipeline (`scripts/release.sh --mas`).

**Not** in Phase 10.1, despite being part of the broader v2 surface — each gets its own spec → plan cycle:

- **Native Anthropic API chat client** — Phase 10.2. The MAS 10.1 build ships *without* the chat panel (button hidden, not greyed). The Developer ID build keeps the existing `claude`-CLI-backed chat.
- **Native GitHub auth** (ASWebAuthenticationSession + git credential helper) — punt to v3. MAS users configure git auth via existing tools (`osxkeychain` credential helper, SSH key). The GitHub auth section in Settings is hidden in MAS.
- **Defense-in-depth sandbox for the DevID build** — explicitly *not* done. DevID stays as-is.
- **Quick Look, Spotlight, Settings polish** — separate Phase 10 sub-projects (10.3 / 10.4 / 10.5 sequence TBD).
- **Tightening the helper's own sandbox** (per-spawn entitlement scoping, sub-helper-per-process isolation) — defense-in-depth future work, doesn't block first MAS release.

## Architecture

### Target structure (`project.yml`)

Three targets, two of them new:

```
targets:
  Anglesite:          # unchanged
    type: application
    sources: [Sources/*]
    entitlements: Resources/Anglesite.entitlements
    bundleID: dev.anglesite.app
    SWIFT_ACTIVE_COMPILATION_CONDITIONS: ""

  AnglesiteMAS:       # new
    type: application
    sources: [Sources/*]
    entitlements: Resources/AnglesiteMAS.entitlements
    bundleID: dev.anglesite.app.mas
    SWIFT_ACTIVE_COMPILATION_CONDITIONS: "ANGLESITE_MAS"
    dependencies:
      - target: AnglesiteHelper
        embed: true
        copy: $(CONTENTS_FOLDER_PATH)/XPCServices

  AnglesiteHelper:    # new — bundled inside AnglesiteMAS only
    type: xpc-service
    sources: [Sources/AnglesiteHelper/*]
    entitlements: Resources/AnglesiteHelper.entitlements
    bundleID: dev.anglesite.app.mas.helper
```

Both app targets share `Sources/AnglesiteApp`, `Sources/AnglesiteCore`, `Sources/AnglesiteBridge` verbatim. Divergence is via `#if ANGLESITE_MAS` (compile flag set on the MAS target only) and a `SupervisorBackend` protocol whose implementation is selected at `ProcessSupervisor.init`. The helper has its own `Sources/AnglesiteHelper/` directory not shared with either app.

Bundle IDs are deliberately different (`…app` vs `…app.mas`) so a developer can install both side-by-side during testing without one overwriting the other.

### `SupervisorBackend` — the protocol that hides the divergence

The single line of code that changes everything is `let process = Process()`. Phase 10.1 hides those behind a protocol the rest of the app doesn't know about:

```swift
public protocol SupervisorBackend: Sendable {
    func spawn(_ spec: SpawnSpec) async throws -> SpawnedProcess
    func runLongLived(_ spec: SpawnSpec) async throws -> LongLivedProcess
    func runOneShot(_ spec: SpawnSpec) async throws -> ProcessResult
    func kill(pid: Int32) async
    func shutdownAll() async
}

public struct SpawnSpec: Sendable, Codable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: URL?
    /// Security-scoped bookmark for the working directory (MAS only; nil for DevID).
    public let workingDirectoryBookmark: Data?
    public let stdinPipe: Bool
    public let logSource: String
}

struct InProcessBackend: SupervisorBackend { /* current Process() code */ }   // DevID
struct XPCBackend: SupervisorBackend { /* NSXPCConnection -> AnglesiteHelper */ }  // MAS
```

`ProcessSupervisor` (the existing actor at `Sources/AnglesiteCore/ProcessSupervisor.swift`) gains an `init(backend: SupervisorBackend)` and picks the right backend at app launch:

```swift
#if ANGLESITE_MAS
public init() { self.init(backend: XPCBackend()) }
#else
public init() { self.init(backend: InProcessBackend()) }
#endif
```

Every existing caller (`AstroDevServer`, `MCPClient.start`, `DeployCommand`, `ClaudeAgent`, `HealthModel`'s build runner) keeps the same `ProcessSupervisor` API. The XPC plumbing is invisible to them. `DeployCommand:279` and `SettingsView:245` (the two direct `Process()` calls outside `ProcessSupervisor`) get migrated to go through `ProcessSupervisor` as part of this work; the `SettingsView` `gh` spawn vanishes in MAS via feature flag (see *Feature flags* below).

### XPC service: `AnglesiteHelper`

A single XPC service per `SiteWindow`, connected lazily on the first spawn, torn down on `onDisappear`:

- Bundled at `AnglesiteMAS.app/Contents/XPCServices/AnglesiteHelper.xpc`.
- Service type `Application` (one helper process per connection, lifetime bound to the connection — closing the XPC connection terminates the helper and reaps every child it spawned).
- Protocol defined in `Sources/AnglesiteCore/XPC/AnglesiteHelperProtocol.swift`, shared between the app and the helper:

```swift
@objc protocol AnglesiteHelperProtocol {
    func spawn(spec: Data, reply: @escaping (Data?, Error?) -> Void)
    func kill(pid: Int32, reply: @escaping (Bool) -> Void)
    func shutdownAll(reply: @escaping () -> Void)
}

@objc protocol HelperClientProtocol {
    func stdoutLine(_ line: String, pid: Int32, source: String)
    func stderrLine(_ line: String, pid: Int32, source: String)
    func processExited(pid: Int32, status: Int32)
}
```

`SpawnSpec` (and `SpawnedProcess` / `ProcessResult`) are `Codable`; the XPC boundary serializes them as `Data`. The helper's `spawn` invokes `Process()` against the executable URL with `workingDirectory` set to the plain absolute path of the site folder (reached via `com.apple.security.inherit` — **not** by resolving a scoped bookmark; see the AMENDED note under *Security-scoped bookmarks* below), sets up stdout/stderr pipes that stream line-by-line back to the app via the inbound `HelperClientProtocol`, and stores the running process keyed by pid for later `kill`. On connection invalidation, `shutdownAll` runs and the helper exits.

The app routes stdout/stderr lines into `LogCenter` exactly as today — same source tags, same Debug pane.

### Security-scoped bookmarks for site folders

In MAS, `~/Sites/<name>/` isn't accessible by default. The grant flow:

- First time the MAS build opens a site (via `Open Folder…` in the launcher, or scaffolding through `/anglesite:start` if that's wired in MAS — but see *Open question 1* below), `NSOpenPanel` returns a URL with implicit access.
- The app immediately calls `url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)` and persists the `Data` on `SiteStore.Site`. The existing `sites.json` schema gains one new field:

  ```swift
  public struct Site: Codable, Sendable {
      // …existing fields…
      public let bookmarkData: Data?   // nil for DevID; populated for MAS
  }
  ```

- Every subsequent open re-resolves the bookmark with `URL(resolvingBookmarkData:options:.withSecurityScope, relativeTo:nil, bookmarkDataIsStale:&isStale)` and calls `startAccessingSecurityScopedResource()`. The window's `onDisappear` calls `stopAccessingSecurityScopedResource()`.

> **AMENDED 2026-05-28 after the Task 6.5 signed-bookmark sub-spike (FAIL).** The original design had the *helper* re-resolve the scoped bookmark from a `SpawnSpec.workingDirectoryBookmark`. **That does not work** — `.withSecurityScope` bookmark resolution across the XPC boundary fails with `NSCocoaErrorDomain 259` *even under real Apple Development signing* (verified; result identical to ad-hoc). App-scoped bookmarks bind to the **creating process identity**, not the Team ID, so the helper (a separate sandbox identity) cannot resolve a bookmark the app created. Notes: [`2026-05-28-bookmark-signed-subspike-notes.md`](2026-05-28-bookmark-signed-subspike-notes.md).
>
> **Corrected design:** the **app** owns the security-scoped grant end to end — it resolves the persisted bookmark and calls `startAccessingSecurityScopedResource()`, holding the grant for the window's lifetime. The **helper never resolves a scoped bookmark.** The helper reaches the site folder via `com.apple.security.inherit` (which extends the app's active powerbox grant to the helper and the children it spawns) using a **plain absolute path** passed in the `SpawnSpec` (the existing `workingDirectory` field). The `workingDirectoryBookmark` field on `SpawnSpec` and the helper's `resolveSpawn` bookmark-resolution code (shipped in Tasks 5/6) become dead and are removed in Task 7.
>
> **Open question still gating Task 7 (not yet verified):** Task 0 confirmed `inherit` lets the helper *read* the top of the selected folder. It is **not yet confirmed** that `inherit` extends the app's scoped grant to the helper's Node child for **writes** (Astro build output, `npm` writing `node_modules`, wrangler's `.wrangler`, image drops writing `public/images/`) and for **subdirectories**, persistently while a long-lived dev server runs. A short confirm-spike of the `inherit` + write path (or, if it fails, fd-passing: the app opens the dir and sends an `NSFileHandle`/fd over XPC) should run before Task 7 locks. Fallback if `inherit` writes don't cover the tree: pass an open fd per spawn, or resolve-in-app and hand the helper a file descriptor it `fchdir`s into.

`SiteStore.identifier(for:)` (currently the path-derived stable string) is unchanged — the bookmark is *additional* state per site, not the identifier.

If a bookmark goes stale (the user moved the folder), the resolve sets `isStale = true`; the app prompts to re-grant access via `NSOpenPanel` and overwrites the persisted bookmark. If the user declines or the folder is missing, the site falls into the `failed("folder unavailable")` `PreviewModel.state` and offers a "Locate folder…" button.

## Entitlements

### `Anglesite` (DevID) — `Resources/Anglesite.entitlements`

Unchanged from today. Sandbox off, hardened-runtime exceptions for JIT and dyld env vars, no MAS-specific keys.

### `AnglesiteMAS` (MAS app) — `Resources/AnglesiteMAS.entitlements`

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
```

Rationale per key:

- `network.client`: WKWebView loading `http://localhost:4321` (the *helper* listens; the *app* only connects out as a client), future Anthropic-API HTTPS, GitHub HTTPS for git push (through the helper).
- `files.user-selected.read-write`: NSOpenPanel grants per-folder access.
- `files.bookmarks.app-scope`: persist security-scoped bookmarks across launches.

Explicitly **omitted**: `temporary-exception` entitlements of any kind, `cs.disable-library-validation`, `application-groups`, `network.server` (the app only consumes the local dev server as a client; the helper does the listening). App groups would let the app and helper share a container; we don't currently have a reason to, and adding them later is non-breaking. If the smoke fixture surfaces a real need for `network.server` on the app, it gets added back then — defaulting to the tightest viable entitlement set.

### `AnglesiteHelper` (XPC service) — `Resources/AnglesiteHelper.entitlements`

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.inherit</key><true/>
<key>com.apple.security.network.server</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
```

Rationale:

- `inherit`: child processes spawned by the helper (Node, wrangler, git) inherit the helper's sandbox profile, including network and file access.
- `network.server`: Astro dev binds `localhost:4321`; MCP server binds an internal pipe but spawns via `Process()` which can need `network.server` for some Node internals.
- `network.client`: wrangler deploys over HTTPS to Cloudflare; git push reaches GitHub over HTTPS.
- `cs.allow-jit` and `cs.allow-unsigned-executable-memory`: Node's V8 needs JIT. These are App Store-compatible (unlike `cs.disable-library-validation`).

## Feature flags for MAS

Three surfaces compile out of MAS via `#if !ANGLESITE_MAS`:

| Surface | Behavior in DevID | Behavior in MAS |
|---|---|---|
| Chat panel (`ChatModel`, `ChatView`, `Chat` button in `SiteWindow` header, `⌘K` shortcut) | Full chat backed by `claude` CLI | Button hidden; Cmd-K does nothing; `ChatModel`/`ChatView` not compiled |
| `SettingsView.GitHubAuthSection` (the `gh auth status` panel) | Existing UI | Section replaced by a single-line note: *"Anglesite uses your existing `git` credentials (macOS Keychain or SSH key)."* with a small `Help` button that opens a `HelpBook` page or — until the help book exists — a `https://anglesite.dev/help/mas-git-setup` URL. |
| Sparkle (`Updater`, `SUFeedURL`, `SUPublicEDKey` in `Info.plist`, "Check for Updates…" menu item) | Sparkle 2.x as today | Compiled out entirely. App Store handles updates. |

The plugin (`Resources/plugin/`) is copied into both bundles unchanged — annotations, the edit overlay, `apply_edit`, the toolbar integration all work in MAS via the XPC-spawned MCP server.

## Bundle structure (MAS)

```
AnglesiteMAS.app/
├── Contents/
│   ├── MacOS/AnglesiteMAS
│   ├── Info.plist                         (MAS-specific; no Sparkle keys)
│   ├── Resources/
│   │   ├── node-runtime/                  (vendored Node, signed)
│   │   ├── plugin/                        (copy of ../anglesite at build time)
│   │   └── edit-overlay/overlay.js
│   ├── XPCServices/
│   │   └── AnglesiteHelper.xpc/
│   │       ├── Contents/MacOS/AnglesiteHelper
│   │       └── Contents/Info.plist
│   └── _CodeSignature/
```

The vendored Node binary stays in the app bundle (not the helper bundle) — the helper resolves its path via `Bundle.main.resourceURL?.appendingPathComponent("node-runtime/bin/node")` at spawn time using the bookmark-scoped resource access pattern. Embedding Node in the app rather than the helper avoids duplicating the binary and matches how the DevID build already works.

## Testing strategy

Two layers, kept deliberately light:

- **Unit (existing `AnglesiteCoreTests`)**: `SupervisorBackend` gets a `MockBackend` for tests that don't actually spawn. All existing `AnglesiteCoreTests` continue to use `InProcessBackend` (no XPC dependency) and stay green unchanged. New tests in `XPCBackendTests.swift` cover the message-serialization layer (`SpawnSpec` round-trip, error propagation through `Codable`) without launching a real helper.
- **MAS smoke fixture** (`scripts/create-smoke-fixture.sh --mas`): builds and runs the `AnglesiteMAS` scheme on a local developer-signed build (no App Store provisioning needed for local), opens a site via `NSOpenPanel` + persists the bookmark, walks the full preview/edit/deploy loop. The helper is exercised end-to-end here — XPC connect, spawn Node, run dev server, route MCP traffic, apply an edit through the overlay, run `npm run build`, deploy via wrangler. Helper stdout is teed to `~/Library/Containers/dev.anglesite.app.mas/Data/Library/Logs/AnglesiteHelper.log` (sandbox-container-scoped, which is where the helper can actually write in MAS) so XPC crashes surface in the fixture output.

No dedicated `AnglesiteHelperTests` integration target. If the helper layer breaks, the smoke fixture catches it. If a unit-level edge case appears, we add a `MockBackend` test then. Don't pay the test-infra cost upfront.

## Submission pipeline

`scripts/release.sh` gains a `--mas` flag that runs an alternate sub-pipeline:

```sh
release.sh --mas <version>
  → xcodebuild archive \
      -scheme AnglesiteMAS \
      -configuration Release \
      -archivePath out/AnglesiteMAS.xcarchive
  → xcodebuild -exportArchive \
      -archivePath out/AnglesiteMAS.xcarchive \
      -exportOptionsPlist scripts/exportOptions-mas.plist \
      -exportPath out/mas/
  → productbuild \
      --component out/mas/AnglesiteMAS.app /Applications \
      --sign "3rd Party Mac Developer Installer: David W. Keith (TEAM_ID)" \
      out/AnglesiteMAS.pkg
  → xcrun altool --upload-app -f out/AnglesiteMAS.pkg \
      -t macos -u "$APPLE_ID" -p "@keychain:AC_PASSWORD"
```

New files:

- `scripts/exportOptions-mas.plist` — `method: app-store-connect`, `signingStyle: manual`, `provisioningProfiles` for `dev.anglesite.app.mas` and `dev.anglesite.app.mas.helper`.
- `docs/release.md` gains a "Mac App Store submission" section with: pre-submission entitlements diff (`codesign -d --entitlements - …` against both bundles), checklist of MAS-incompatible patterns to confirm absent (`temporary-exception`, Sparkle frameworks, `claude` CLI references in the MAS binary), and App Store Connect metadata template.

The DevID path of `release.sh` is unchanged.

## Spike results (Task 0 + Node sub-spike) — read before the risks table

The Task 0 verification spike and a follow-up Node sub-spike ran on macOS 26.5 (Tahoe) under ad-hoc signing. Notes: [`2026-05-27-sandboxed-app-store-spike-notes.md`](2026-05-27-sandboxed-app-store-spike-notes.md), [`2026-05-28-node-sandbox-subspike-notes.md`](2026-05-28-node-sandbox-subspike-notes.md). Three load-bearing results, each of which revises the design:

**1. The core capability works.** A sandboxed XPC helper *can* `Process()`-spawn child binaries against a user-selected folder, and — critically — it can spawn the **vendored Node binary**, init V8 (`cs.allow-jit` is sufficient; `disable-library-validation` is *not* needed), and bind a localhost port (`network.server`). The helper entitlement set in this spec is confirmed sufficient. This is the question the whole milestone rested on, and the answer is yes.

**2. `/usr/bin/git` is blocked — but this is a *plugin*-side concern, not Swift, and it degrades gracefully.** `/usr/bin/git` on modern macOS is the `xcrun` shim, which refuses to run inside `app-sandbox` (confirmed; `DEVELOPER_DIR` does not bypass). The original spec assumed git was spawned from Swift via `ProcessSupervisor` and proposed a libgit2/SwiftGit2 fallback. **That assumption was wrong.** Anglesite's Swift code invokes no `git`. The only `git` usage is in the **plugin's Node MCP server** — `server/edit-history.mjs` and `server/undo-edit.mjs` (`execFileSync("git", …)`), which back the per-edit undo feature.

  Crucially, `recordEdit` is **best-effort**: `apply-edit-dispatcher.mjs` wraps the `onApplied` hook in try/catch (lines 206–212), so when the git call fails the edit still applies and returns `commit: undefined`. The Swift `MCPApplyEditRouter` already treats `commit == nil` as "not undo-able" and surfaces no undo row. And the per-edit undo *UI* lives entirely in the chat panel (`Role.edit` rows in `ChatView`) — which is **already cut from the MAS build** (see *Feature flags*). So in MAS: `edit-history.mjs`'s git calls fail harmlessly under the sandbox, edits still apply, and there is no undo UI to break because it travels with the chat panel.

  **Net effect: no libgit2, no Swift git rewrite, no plugin change for Phase 10.1.** Per-edit undo is simply absent from the MAS build in 10.1 — deferred alongside chat. Bringing undo back to MAS (a Phase 10.2+ concern, when chat returns) will require a sandbox-safe git in the plugin's Node code (isomorphic-git is the likely path — pure-JS, covers the shallow plumbing set used: `rev-parse`, `diff`, `hash-object`, `write-tree`, `commit-tree`, `update-ref`). That is explicitly out of scope here and gets its own cross-repo spec.

**3. Security-scoped bookmark resolution across XPC is unverified under real signing.** `URL(resolvingBookmarkData:options:.withSecurityScope)` in the helper fails with `NSCocoaErrorDomain 259` under **ad-hoc** signing (the scopedbookmarksagent can't validate the creator identity without a Team ID). A *plain* (non-scope) bookmark resolves fine, and `com.apple.security.inherit` gives the helper the same powerbox access the app holds, which covered every read the spike tested. **Whether `.withSecurityScope` works under a real Apple Development / Distribution cert is untested** (no cert was installed on the spike machine). This is gated by a follow-up signed-build sub-spike before Task 7; if scoped resolution still fails under real signing, the bookmark-passing design changes (resolve in the app, pass an open `NSFileHandle` to the helper, or rely on `inherit` + plain bookmark for path recovery).

## Risks

### Now-resolved (was "could derail MAS"): git from the sandbox

Superseded by spike result #2 above. Git is plugin-side Node, best-effort, and absent from MAS 10.1 along with the chat-panel undo UI. No libgit2 fallback is needed for this milestone. Documented here so the original risk isn't mistaken for still-open.

### Lower-priority risks

| Risk | Mitigation |
|---|---|
| App Store reviewer flags the embedded Node binary | Node lives in the app bundle, signed with our cert, spawned only by code we wrote — same pattern as VS Code's MAS shim, Electron-MAS apps, Slack MAS, etc. Node-in-sandbox spawn is **confirmed** (sub-spike). Re-signing Node to our own Team ID is a MAS packaging step near Task 11/12 (App Store requires bundled executables signed with the submitter's identity); not a launch-blocker (the sub-spike ran Node with its original foreign Team ID under ad-hoc). |
| `wrangler` from the site's `node_modules/.bin/` | wrangler is a Node script; the helper spawns Node (confirmed), Node runs wrangler, wrangler deploys over HTTPS (`network.client` granted). The Node-spawn mechanism is verified; wrangler's *own* end-to-end behavior in-sandbox (a real `wrangler deploy`) is **untested** — verify in the Task 11 smoke fixture. |
| Bookmark `.withSecurityScope` resolution may fail under real signing | See spike result #3. Gated by a signed-build sub-spike before Task 7. Interim fallback: `inherit` + plain bookmark for path recovery. |
| XPC connection setup latency on first spawn | Measure during smoke test; in practice ~10ms for the first connect, then negligible. Eat the cost — preview spin-up is already dominated by Astro startup (~2s). |
| WKWebView in MAS can't load `http://localhost:4321` over plain HTTP | `NSAllowsLocalNetworking` is already present in `Info.plist` and the MAS app inherits it. Verify in smoke fixture. |
| Astro's filesystem watcher behaves differently inside the helper's sandbox | The helper's `inherit` entitlement should pass file-watcher API access to Node. Verify in smoke fixture; if watching breaks, fall back to polling with `--force-polling` (Astro supports it). |
| Helper crash leaves orphan child processes | `NSXPCConnection.invalidate` triggers the connection's `invalidationHandler` in the helper, which calls `shutdownAll`. If the helper itself crashes, launchd reaps the service and the spawned children become reparented to launchd; the app's next connection sets up fresh state. Acceptable — same blast radius as the DevID build losing the app process. |
| Sparkle removal breaks the existing menu structure | The "Check for Updates…" menu item is wrapped in `#if !ANGLESITE_MAS`. Menu layout is otherwise unchanged. |

## Non-goals

Re-stating from *Scope and explicit deferrals* in one place to avoid the spec creeping into adjacent work:

- Native Anthropic API chat client — Phase 10.2.
- **Per-edit undo in the MAS build — Phase 10.2+.** The undo UI lives in the chat panel (cut from MAS 10.1), and the plugin's git-backed `recordEdit` fails harmlessly under the sandbox. Restoring undo to MAS needs a sandbox-safe git in the plugin's Node code (isomorphic-git) — a cross-repo change with its own spec.
- Native GitHub auth (OAuth + git credential helper) — v3.
- Defense-in-depth sandboxing of the DevID build — out of scope; DevID stays non-sandboxed.
- Quick Look, Spotlight, Settings polish — separate Phase 10 sub-projects.
- Tightening the helper's sandbox per-spawn or sub-helper-per-process — future defense-in-depth work.
- Cross-platform builds (Linux/Windows) — not on the roadmap.
- Replacing vendored Node with a WebAssembly runtime — investigated under "Would Docker help?" in brainstorming; doesn't fit the file-watching performance budget for `astro dev`.

## Open questions

1. **Site scaffolding flow in MAS.** Today `/anglesite:start` (a Claude skill in the plugin) scaffolds a new site. In MAS without the chat panel, the user has no way to invoke that skill from inside the app. Three options to resolve before Task 1 of the implementation plan: (a) ship MAS with an "Import existing site" flow only — assume users created the site outside MAS via `claude` CLI + `/anglesite:start`; (b) add a native "New site…" wizard in the MAS launcher that drives the same MCP tool the skill calls (since the plugin's MCP server runs in both builds); (c) defer to Phase 10.2 when chat lands and the skill is reachable again. Recommendation: (a) for 10.1 — keep scope tight; users adopting MAS first are likely also installing the plugin separately. Revisit in 10.2.

2. **macOS minimum version.** Currently macOS 14 (Sonoma). XPC services have worked since 10.7; security-scoped bookmarks since 10.7.3. No deployment-target bump needed.

3. **Bundle ID strategy for App Store Connect.** Confirmed in brainstorming: separate bundle IDs (`dev.anglesite.app` vs `dev.anglesite.app.mas`). The MAS bundle is a new App Store Connect record.

4. **Helper bundle ID format.** `dev.anglesite.app.mas.helper` is the convention used elsewhere (the helper's bundle ID is the app's bundle ID plus `.helper`). Apple's docs don't require this but Xcode's defaults expect it.

5. **Disabling Anglesite-app#6's primed npm cache for MAS?** The primed cache is `Resources/primed-npm-cache.tar.zst` extracted at first launch into `~/Library/Application Support/.../npm-cache/`. In MAS, that's `~/Library/Containers/dev.anglesite.app.mas/Data/Library/Application Support/…` — inside the sandbox container, fine. No change needed. Flagged because cache write paths often surprise sandboxed apps.
