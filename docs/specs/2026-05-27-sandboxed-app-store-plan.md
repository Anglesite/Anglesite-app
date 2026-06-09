# Sandboxed Mac App Store build — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Anglesite on the Mac App Store as a sandboxed second target (`AnglesiteMAS`) alongside the existing Developer ID build (`Anglesite`), without the chat panel (deferred to Phase 10.2).

**Architecture:** Introduce a `SupervisorBackend` protocol that `ProcessSupervisor` delegates to; refactor the existing direct-`Process()` code into `InProcessBackend` (used by DevID); build an `XPCBackend` that talks to a new `AnglesiteHelper` XPC service (used by MAS). Security-scoped bookmarks per site, threaded through XPC. MAS-specific entitlements; chat / Sparkle / `gh` Settings panel compiled out via `#if !ANGLESITE_MAS`.

**Tech Stack:** Swift 5.10 / SwiftUI / actors, XPC services (`NSXPCConnection`), Apple App Sandbox + Hardened Runtime, xcodegen, `xcodebuild`, vendored Node.js runtime.

**Reference spec:** [`docs/specs/2026-05-27-sandboxed-app-store-design.md`](2026-05-27-sandboxed-app-store-design.md) — read first if any task is ambiguous.

---

## ⚠️ ARCHITECTURE PIVOT (2026-05-28) — READ FIRST; supersedes the XPC-helper task structure below

Seven spikes (Task 0, sub-spikes B/Node, 6.5, 6.6, 6.7 — notes files dated 2026-05-27/28) reshaped this plan. The headline: **the XPC helper is removed.** It was built on a false premise (that a sandboxed app can't spawn subprocesses). The validated architecture:

**MAS app = sandboxed + the SAME `InProcessBackend` as DevID.** The app spawns Node/Astro/wrangler directly via `Process()`. Per `SiteWindow`, the app resolves the site's persisted security-scoped bookmark and `startAccessingSecurityScopedResource()`, holding the grant for the window's lifetime; **direct children inherit the grant** (proven in 6.7 — `/bin/sh` and bundled Node both wrote absolute paths throughout a granted folder; never-granted folder EPERM'd). No `AnglesiteHelper`, no `XPCBackend`, no XPC protocol.

### What this means for shipped work

- **KEEP:** Task 1 (`AnglesiteMAS` target + entitlements), Task 2 (`SupervisorBackend`), Task 3 (`InProcessBackend` + facade). The `SupervisorBackend` protocol stays as a clean seam; `InProcessBackend` is now its only implementation.
- **REVERT (Task R below):** Task 4 (`Sources/AnglesiteCore/XPC/AnglesiteHelperProtocol.swift`), Task 5 (`Sources/AnglesiteHelper/`, helper entitlements + Info.plist, the `AnglesiteHelper` target + embed in `project.yml`), Task 6 (`Sources/AnglesiteCore/XPCBackend.swift`). Also: `ProcessSupervisor.init`'s `#if ANGLESITE_MAS` branch now uses `InProcessBackend()` (not `XPCBackend()`); remove `SpawnSpec.workingDirectoryBookmark` (no boundary to cross); fold `SpawnTypes.swift` back into `SupervisorBackend.swift` or leave it (harmless).

### Established facts that still hold

1. **Node runs under App Sandbox** — but under **hardened runtime**, the bundled Node binary itself must carry `cs.allow-jit` + `cs.allow-unsigned-executable-memory` + `inherit` + `app-sandbox` or V8 OOMs at launch (`Failed to reserve virtual memory for CodeRange`). The ad-hoc sub-spike missed this. **Load-bearing for the Node re-sign (Task N below + Task 12).**
2. **`/usr/bin/git` blocked in-sandbox**, but git is plugin-side Node, best-effort (dispatcher catches; edit still applies with `commit: undefined`), and per-edit undo's UI rides in the chat panel cut from MAS. So per-edit undo is simply absent from MAS 10.1. No libgit2, no plugin change. (This now applies to the app's *own* spawned Node MCP server too — when it shells out to git it'll fail best-effort, fine.)
3. **WWDR G3 intermediate gotcha (Task 12):** the Apple Development cert reads "0 valid identities" until WWDR CA **G3** is installed. CI/release must import it and assert `security find-identity -v -p codesigning` ≥ 1 before signing. Fixed locally 2026-05-28 via `apple.com/certificateauthority/AppleWWDRCAG3.cer`.
4. Untested, verify at Task 11/12: real `wrangler deploy` + full `astro dev` in-sandbox, Node→grandchild grant inheritance, file-watching under sandbox, Distribution-profile signing, cross-launch bookmark persistence, macOS 14/15.

### Revised remaining task roadmap (replaces old Tasks 7–13)

- **Task R — Revert the XPC helper layer.** Remove the helper target/sources/entitlements/Info.plist + embed from `project.yml`; delete `XPCBackend.swift` + `AnglesiteHelperProtocol.swift`; point `ProcessSupervisor.init` MAS branch at `InProcessBackend()`; drop `SpawnSpec.workingDirectoryBookmark`. Both schemes build; full suite green (`--parallel`); DevID smoke green.
- **Task 7 (revised) — App-held per-site security-scoped grant.** `SiteStore.Site.bookmarkData: Data?` (kept from the original Task 7). MAS `Open Folder…` creates + persists the scoped bookmark; `SiteWindow.loadAndStart` resolves it and `startAccessingSecurityScopedResource()`, `onDisappear` stops. Stale-bookmark re-grant flow. NO bookmark crosses any process boundary — the app holds the grant and spawns directly. `#if ANGLESITE_MAS` guards the grant calls (DevID has no bookmark/grant).
- **Task N — Bundled Node re-sign for sandbox.** A build step (re-sign `Resources/node-runtime/bin/node` — and any other Mach-O under node-runtime — with the app's identity + an entitlements plist carrying `app-sandbox`/`inherit`/`cs.allow-jit`/`cs.allow-unsigned-executable-memory`) so V8 runs under the MAS app's hardened runtime. Wire into the MAS target's build phases / `scripts/`. (This also subsumes the deferred DevID Node re-sign #1/#4 conceptually, but scope to MAS here.)
- **Task 8 — Migrate the 2 direct `Process()` sites** (`DeployCommand` env/wrangler, `SettingsView` `gh`) through `ProcessSupervisor`. Unchanged from original. (`gh` is then compiled out of MAS in Task 10.)
- **Task 9 — Chat out of MAS** (`#if !ANGLESITE_MAS`). Unchanged.
- **Task 10 — Sparkle + `gh` Settings out of MAS.** Sparkle slice already done in Task 1; finish the `gh` Settings variant.
- **Task 11 — MAS smoke fixture.** Build/run the `AnglesiteMAS` scheme (real-signed, Node re-signed), set up a per-site scoped grant, drive the full preview/edit/**write-heavy** loop (Astro build writing `dist/`, npm, image drop into `public/images/`), and a real `wrangler` invocation. Node discovery must handle **nvm**-installed node (the existing e2e MCP test only probes `/opt/homebrew`,`/usr/local`,`/usr/bin` and skips under nvm — fix or note). No helper to exercise anymore.
- **Task 12 — Release pipeline + docs.** MAS archive/export/`productbuild`/upload + the Node re-sign step + the WWDR G3 preflight check + entitlements diff (no helper to check now). `docs/release.md` MAS section.
- **Task 13 — Final integration check + build-plan/CLAUDE.md flip.** Both schemes build, suite green, MAS smoke green, docs updated.

The detailed task bodies below (old Tasks 4–13) are **historical** except where this roadmap says "unchanged" — follow this roadmap, not the old XPC-helper task text.

## Pre-flight reading for any implementer

Before starting any task, an implementer subagent should read:

- This plan, in full, with attention to the task immediately preceding theirs (cross-task type signatures must match).
- The design spec section corresponding to their task.
- The files listed under that task's **Files** header — at minimum, skim the regions being modified.
- `CLAUDE.md` and `.claude/CLAUDE.md` for project-wide conventions (commit format, "main branch is working branch," ES modules / vanilla preferred where applicable).

Build / test commands implementers will need (all from repo root, no `cd` needed):

```sh
# Tests (use these — NOT `xcodebuild ... -scheme Anglesite-Package`)
swift test --package-path .                         # full SPM test suite
swift test --package-path . --filter <TestName>     # one test

# Builds
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build         # DevID baseline (must stay green every task)
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build      # MAS (exists after Task 1)
xcodebuild -project Anglesite.xcodeproj -target AnglesiteHelper -configuration Debug build   # helper alone (exists after Task 5)

# Regenerate xcodeproj after any project.yml edit
xcodegen generate

# Smoke fixtures
scripts/create-smoke-fixture.sh           # existing DevID smoke (must stay green)
scripts/create-smoke-fixture.sh --mas     # MAS smoke (exists after Task 11)
```

**Project conventions** (do not violate without explicit user instruction):

1. Commits land directly on `main`. No feature branches for this work.
2. `xcodegen` is the source of truth for the `.xcodeproj`. **Never** hand-edit `Anglesite.xcodeproj/project.pbxproj` — edit `project.yml`, run `xcodegen generate`. A git pre-commit hook auto-regenerates the project from `project.yml`; trust it.
3. Existing tests stay green every commit. The DevID build (`Anglesite` scheme) keeps shipping unchanged behavior throughout.
4. Conventional-commit format (`feat(scope): subject`), `Co-Authored-By:` trailer at the end.

---

## File map

**New files** (with one-line responsibilities):

| Path | Responsibility |
|---|---|
| `Sources/AnglesiteCore/SupervisorBackend.swift` | Protocol + `SpawnSpec` / `SpawnedProcess` / `ProcessResult` Codable types — the API every subprocess caller will use. |
| `Sources/AnglesiteCore/InProcessBackend.swift` | DevID backend — wraps `Process()` directly. Refactored out of `ProcessSupervisor`. |
| `Sources/AnglesiteCore/XPCBackend.swift` | MAS backend — `NSXPCConnection` wrapper. Only compiled when `ANGLESITE_MAS` is set. |
| `Sources/AnglesiteCore/XPC/AnglesiteHelperProtocol.swift` | `@objc protocol` definitions shared between app and helper. |
| `Sources/AnglesiteCore/SecurityScopedBookmark.swift` | Bookmark create / resolve / refresh-on-stale logic. Used by app and helper. |
| `Sources/AnglesiteHelper/main.swift` | XPC service entry point — sets up `NSXPCListener.service()`. |
| `Sources/AnglesiteHelper/HelperService.swift` | Implements `AnglesiteHelperProtocol`. Spawns and tracks child processes; pipes stdout/stderr back over XPC. |
| `Resources/AnglesiteMAS.entitlements` | App-sandbox + network.client + file bookmarks. |
| `Resources/AnglesiteHelper.entitlements` | App-sandbox + inherit + network + JIT for Node. |
| `Resources/AnglesiteMAS-Info.plist` | MAS app Info.plist — no Sparkle keys. |
| `Resources/AnglesiteHelper-Info.plist` | XPC service Info.plist. |
| `scripts/exportOptions-mas.plist` | `xcodebuild -exportArchive` config for App Store Connect. |
| `Tests/AnglesiteCoreTests/SupervisorBackendTests.swift` | `MockBackend`, `SpawnSpec` Codable round-trip. |
| `Tests/AnglesiteCoreTests/SecurityScopedBookmarkTests.swift` | Bookmark create / resolve / stale handling. |

**Modified files:**

| Path | What changes |
|---|---|
| `project.yml` | Add `AnglesiteMAS` and `AnglesiteHelper` targets; add `AnglesiteMAS` scheme; wire helper embed. |
| `Sources/AnglesiteCore/ProcessSupervisor.swift` | Becomes a thin facade over `SupervisorBackend`; spawn code moves to `InProcessBackend`. Public API unchanged. |
| `Sources/AnglesiteCore/SiteStore.swift` | `Site.bookmarkData: Data?`; bookmark-stamping on add. |
| `Sources/AnglesiteCore/DeployCommand.swift` | Replace direct `Process()` at line 279 with `ProcessSupervisor.run(...)`. |
| `Sources/AnglesiteApp/SettingsView.swift` | Replace direct `Process()` at line 245; wrap `GitHubAuthSection` in `#if !ANGLESITE_MAS`. |
| `Sources/AnglesiteApp/ChatModel.swift` | Wrap file body in `#if !ANGLESITE_MAS`. |
| `Sources/AnglesiteApp/ChatView.swift` | Wrap file body in `#if !ANGLESITE_MAS`. |
| `Sources/AnglesiteApp/SiteWindow.swift` | Wrap chat button + Cmd-K + `ChatModel` field in `#if !ANGLESITE_MAS`. |
| `Sources/AnglesiteApp/Updater.swift` | Wrap file body in `#if !ANGLESITE_MAS`; conditional `import Sparkle`. |
| `Resources/Info.plist` | Stays as the DevID `Info.plist`. Unchanged. |
| `scripts/release.sh` | `--mas` flag → archive + productbuild + altool sub-pipeline. |
| `scripts/create-smoke-fixture.sh` | `--mas` flag → build MAS scheme, set bookmark, run smoke through XPC. |
| `docs/release.md` | New "Mac App Store submission" section. |
| `docs/build-plan.md` | Mark Phase 10.1 in progress / complete on PR landing. |
| `CLAUDE.md` | Update "Current phase" pointer when phase wraps. |

---

## Task 0: Verification spike — sandboxed XPC can spawn `/usr/bin/git`

**Why this exists:** The biggest single risk in the spec (§Critical risk) — App Store reviewers occasionally reject apps for spawning non-app-bundle executables from a sandboxed XPC service. Confirm it works (or find out it doesn't) *before* any architectural work lands.

**Time-box:** 1 day. If the spike fails on macOS 14 or 15, stop and consult the user. The fallback (libgit2 / SwiftGit2) roughly doubles the milestone scope and needs an updated plan.

**Files:**
- Create (throwaway): `/tmp/SandboxSpike/SandboxSpike.xcodeproj` + `Sources/`. Disposable test project, not committed.
- Modify: none.

- [ ] **Step 1: Create a throwaway sandboxed app + XPC service.**

In a scratch directory (`mkdir -p /tmp/SandboxSpike && cd /tmp/SandboxSpike`), create a minimal SwiftUI macOS app with one button and an embedded XPC service. Sandboxing on with these entitlements on the helper:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.inherit</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.network.client</key><true/>
```

The helper's only method:

```swift
@objc protocol Probe {
    func runGit(bookmark: Data, reply: @escaping (String, Int32) -> Void)
}

@objc final class ProbeImpl: NSObject, Probe {
    func runGit(bookmark: Data, reply: @escaping (String, Int32) -> Void) {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), url.startAccessingSecurityScopedResource() else {
            reply("bookmark resolution failed", -1)
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["status"]
        p.currentDirectoryURL = url
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do {
            try p.run()
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            reply(String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
        } catch {
            reply("spawn failed: \(error)", -1)
        }
    }
}
```

App side: `NSOpenPanel` to pick a folder, `url.bookmarkData(options: .withSecurityScope, ...)`, connect to the XPC service, call `runGit(bookmark:reply:)`, log the output.

- [ ] **Step 2: Run on macOS 14.**

Build the spike, sign with a Mac Developer cert (Personal Team is fine), launch, pick the repo root of any local git checkout. Expected: `git status` output prints, exit code `0`.

- [ ] **Step 3: Run on macOS 15.**

Repeat the test on a macOS 15 machine or VM. (If no macOS 15 environment is available, document this in the implementation notes and proceed on macOS 14 only; the next implementer covers macOS 15 verification.) Expected: same result.

- [ ] **Step 4: Record the outcome.**

Create `docs/specs/2026-05-27-sandboxed-app-store-spike-notes.md` with:
- macOS version(s) tested
- Pass/fail per version
- Exact stdout/stderr captured
- Any unexpected entitlement requirements discovered
- Any warnings in `Console.app` during the run (sandbox violations, even non-fatal, are worth recording)

If **all versions pass**, proceed to Task 1.

If **any version fails**, stop. Re-read §Critical risk in the spec; the libgit2/SwiftGit2 fallback is the named alternative. Open an issue summarizing the failure, attach the spike output, and consult the user before continuing.

- [ ] **Step 5: Commit (notes only).**

```sh
git add docs/specs/2026-05-27-sandboxed-app-store-spike-notes.md
git commit -m "$(cat <<'EOF'
docs(specs): phase 10.1 — XPC + /usr/bin/git spike notes

Result of the 1-day verification spike from
docs/specs/2026-05-27-sandboxed-app-store-plan.md Task 0. Confirms
that a sandboxed XPC service can spawn /usr/bin/git against a
bookmark-scoped folder on the macOS versions tested. Phase 10.1
proceeds with the spec as written.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

The throwaway spike project is *not* committed.

---

## Task 1: Add `AnglesiteMAS` target scaffold (no code yet — target compiles, runs an empty SwiftUI app)

**Files:**
- Create: `Resources/AnglesiteMAS-Info.plist`
- Create: `Resources/AnglesiteMAS.entitlements`
- Modify: `project.yml`

- [ ] **Step 1: Add `Resources/AnglesiteMAS-Info.plist`.**

Create the file as a copy of the existing `Resources/Info.plist` with these differences: no `SUFeedURL`, no `SUPublicEDKey`, no `SUEnableAutomaticChecks`, no `SUEnableInstallerLauncherService`. Keep `NSAllowsLocalNetworking`, `NSAppleEventsUsageDescription`, version strings.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Anglesite</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 David W. Keith. ISC License.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Anglesite needs to coordinate with helper processes (Astro dev server, MCP server) to preview and edit your site.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
```

- [ ] **Step 2: Add `Resources/AnglesiteMAS.entitlements`.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Mac App Store target: sandbox on. -->
    <key>com.apple.security.app-sandbox</key><true/>

    <!-- WKWebView loads http://localhost:<helper-port>; future Anthropic API + git push are HTTPS through the helper. -->
    <key>com.apple.security.network.client</key><true/>

    <!-- NSOpenPanel grants per-folder access; persist across launches via bookmarks. -->
    <key>com.apple.security.files.user-selected.read-write</key><true/>
    <key>com.apple.security.files.bookmarks.app-scope</key><true/>
</dict>
</plist>
```

- [ ] **Step 3: Add the target and scheme to `project.yml`.**

Insert these under `targets:` after the existing `Anglesite:` target block (keep `Anglesite:` untouched). The MAS target shares all sources with `Anglesite:` except `Updater.swift` (Sparkle); that's handled via `#if !ANGLESITE_MAS` in Task 10, not by excluding the file:

```yaml
  AnglesiteMAS:
    type: application
    platform: macOS
    sources:
      - path: Sources/AnglesiteApp
      - path: Resources/Assets.xcassets
      - path: Resources/node-runtime
        type: folder
        buildPhase: resources
        optional: true
      - path: Resources/plugin
        type: folder
        buildPhase: resources
        optional: true
      - path: Resources/npm-cache
        type: folder
        buildPhase: resources
        optional: true
      - path: Resources/edit-overlay
        type: folder
        buildPhase: resources
        optional: true
    preBuildScripts:
      - name: Vendor Node runtime
        script: "${PROJECT_DIR}/scripts/vendor-node.sh"
        basedOnDependencyAnalysis: false
      - name: Bundle Anglesite plugin
        script: "${PROJECT_DIR}/scripts/copy-plugin.sh"
        basedOnDependencyAnalysis: false
      - name: Vendor primed npm cache
        script: "${PROJECT_DIR}/scripts/vendor-npm-cache.sh"
        basedOnDependencyAnalysis: false
      - name: Build edit overlay
        script: "${PROJECT_DIR}/scripts/build-overlay.sh"
        basedOnDependencyAnalysis: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.anglesite.app.mas
        PRODUCT_NAME: Anglesite
        INFOPLIST_FILE: Resources/AnglesiteMAS-Info.plist
        GENERATE_INFOPLIST_FILE: NO
        CODE_SIGN_ENTITLEMENTS: Resources/AnglesiteMAS.entitlements
        ENABLE_HARDENED_RUNTIME: YES
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        SWIFT_VERSION: "5.10"
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: "0.1.0"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        COMBINE_HIDPI_IMAGES: YES
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: ANGLESITE_MAS
      configs:
        Debug:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Apple Development"
        Release:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Apple Distribution"
    dependencies:
      - package: Anglesite
        product: AnglesiteCore
      - package: Anglesite
        product: AnglesiteBridge
```

Under `schemes:` add a new scheme block paralleling the existing `Anglesite:` scheme, just substituting `AnglesiteMAS`:

```yaml
  AnglesiteMAS:
    build:
      targets:
        AnglesiteMAS: all
    run:
      config: Debug
      executable: AnglesiteMAS
    test:
      config: Debug
    profile:
      config: Release
    analyze:
      config: Debug
    archive:
      config: Release
```

- [ ] **Step 4: Regenerate the xcodeproj.**

```sh
xcodegen generate
```

Expected: `Created project at Anglesite.xcodeproj`. No errors, no warnings about missing files.

- [ ] **Step 5: Build the new target.**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. The MAS build at this point is functionally identical to the DevID build except for the entitlements / Info.plist / compile flag — no XPC, no helper, just sandbox on (which will cause runtime breakage when actually used — fine, we're verifying it compiles and links).

- [ ] **Step 6: Build the DevID target as a regression check.**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. Unchanged behavior.

- [ ] **Step 7: Commit.**

```sh
git add project.yml Resources/AnglesiteMAS-Info.plist Resources/AnglesiteMAS.entitlements Anglesite.xcodeproj
git commit -m "$(cat <<'EOF'
feat(mas): scaffold AnglesiteMAS target (compiles; not yet wired up)

Adds the second Xcode target for the Mac App Store distribution. Same
SwiftUI sources as DevID; differs only in entitlements (sandbox on),
Info.plist (no Sparkle keys), bundle ID (dev.anglesite.app.mas), and
the ANGLESITE_MAS compile flag. No XPC plumbing yet — that lands in
later tasks. The MAS build is non-functional at runtime (Process()
calls will fail under sandbox) until Task 6 wires up the helper.

Phase 10.1 Task 1 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `SupervisorBackend` protocol + Codable spec types

**Files:**
- Create: `Sources/AnglesiteCore/SupervisorBackend.swift`
- Create: `Tests/AnglesiteCoreTests/SupervisorBackendTests.swift`

- [ ] **Step 1: Write the failing test for `SpawnSpec` Codable round-trip.**

`Tests/AnglesiteCoreTests/SupervisorBackendTests.swift`:

```swift
import XCTest
@testable import AnglesiteCore

final class SupervisorBackendTests: XCTestCase {
    func test_spawnSpec_codable_roundTrip() throws {
        let original = SpawnSpec(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["status", "--porcelain"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: URL(fileURLWithPath: "/tmp/site"),
            workingDirectoryBookmark: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            stdinPipe: true,
            logSource: "git:status"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpawnSpec.self, from: encoded)

        XCTAssertEqual(decoded, original)
    }

    func test_spawnSpec_codable_nilFieldsRoundTrip() throws {
        let original = SpawnSpec(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hi"],
            environment: nil,
            workingDirectory: nil,
            workingDirectoryBookmark: nil,
            stdinPipe: false,
            logSource: "echo"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpawnSpec.self, from: encoded)

        XCTAssertEqual(decoded, original)
    }
}
```

- [ ] **Step 2: Run test to verify it fails.**

```sh
swift test --package-path . --filter SupervisorBackendTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find 'SpawnSpec' in scope`.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/SupervisorBackend.swift`.**

```swift
import Foundation

/// One spawn request, fully described and serializable. Crossing the XPC boundary requires
/// `Codable`; we use the same struct in-process too so DevID and MAS share one call shape.
public struct SpawnSpec: Sendable, Codable, Equatable {
    /// Absolute path to the executable. Bundled binaries (Node, helper-internal tools) and system
    /// binaries (`/usr/bin/git`, `/usr/bin/env`) both go through this field.
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: URL?
    /// Security-scoped bookmark for `workingDirectory`. MAS-only; the XPC helper resolves and
    /// `startAccessingSecurityScopedResource()`s before spawning. `nil` for DevID (no sandbox).
    public let workingDirectoryBookmark: Data?
    /// When `true`, the spawned process gets a writable stdin pipe (MCP JSON-RPC framing needs this).
    public let stdinPipe: Bool
    /// Tag used by `LogCenter` when streaming stdout/stderr — e.g. `"astro:dev:<siteID>"`.
    public let logSource: String

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        workingDirectoryBookmark: Data? = nil,
        stdinPipe: Bool = false,
        logSource: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.workingDirectoryBookmark = workingDirectoryBookmark
        self.stdinPipe = stdinPipe
        self.logSource = logSource
    }
}

/// Result of a one-shot `runOneShot` call.
public struct ProcessResult: Sendable, Codable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Opaque token identifying a long-lived spawned process. The backend maps this to whatever
/// it tracks internally (a `Process` for InProcess, a pid + connection for XPC).
public struct SpawnedProcessHandle: Sendable, Codable, Equatable, Hashable {
    public let id: UUID
    public let pid: Int32

    public init(id: UUID = UUID(), pid: Int32) {
        self.id = id
        self.pid = pid
    }
}

public enum SupervisorBackendError: Error, Sendable {
    case spawnFailed(String)
    case unknownHandle
    case bookmarkResolutionFailed(String)
    case backendUnavailable(String)
}

/// The single seam between `ProcessSupervisor` and the underlying spawn mechanism.
///
/// - `InProcessBackend` (DevID): wraps `Process()` directly. No sandbox.
/// - `XPCBackend` (MAS): sends spawn requests to `AnglesiteHelper` over `NSXPCConnection`.
///
/// `ProcessSupervisor` picks one at init time and never branches on which is in use after that.
public protocol SupervisorBackend: Sendable {
    /// Synchronous one-shot. Spawns, drains stdout+stderr concurrently, waits for exit.
    func runOneShot(_ spec: SpawnSpec) async throws -> ProcessResult

    /// Long-lived spawn. Returns once the process is launched. Stdout/stderr lines flow into
    /// `LogCenter` tagged with `spec.logSource`. The caller uses `terminate(handle:)` to stop it
    /// and `waitForExit(handle:)` to await final disposition.
    func launch(_ spec: SpawnSpec) async throws -> SpawnedProcessHandle

    /// SIGTERM → SIGKILL escalation after `timeout`. No-op if the handle is unknown or already exited.
    func terminate(_ handle: SpawnedProcessHandle, timeout: TimeInterval) async

    /// Stop every process the backend is tracking. Called on app quit / window close.
    func shutdownAll(timeout: TimeInterval) async

    /// Writes `bytes` to the spawned process's stdin. Throws if `spec.stdinPipe` was false.
    /// Used by `MCPClient` for JSON-RPC framing.
    func writeStdin(_ handle: SpawnedProcessHandle, _ bytes: Data) async throws
}
```

- [ ] **Step 4: Run test to verify it passes.**

```sh
swift test --package-path . --filter SupervisorBackendTests 2>&1 | tail -10
```

Expected: 2 passed, 0 failed.

- [ ] **Step 5: Make sure the full suite still passes.**

```sh
swift test --package-path . 2>&1 | tail -5
```

Expected: all existing tests still pass; 2 new tests pass.

- [ ] **Step 6: Commit.**

```sh
git add Sources/AnglesiteCore/SupervisorBackend.swift Tests/AnglesiteCoreTests/SupervisorBackendTests.swift
git commit -m "$(cat <<'EOF'
feat(core): SupervisorBackend protocol + Codable SpawnSpec types

The single seam between ProcessSupervisor and the spawn mechanism.
Defined now so the next task can refactor the existing Process() body
into InProcessBackend without changing the public API of
ProcessSupervisor. The XPC backend (Task 6) plugs into the same
protocol; SpawnSpec is Codable specifically so it can cross the XPC
boundary unchanged.

Phase 10.1 Task 2 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Refactor `ProcessSupervisor` → `InProcessBackend` (no behavior change)

**Goal:** Move the existing spawn code into `InProcessBackend`. `ProcessSupervisor` becomes a thin facade that delegates to a `SupervisorBackend`. **Every existing caller of `ProcessSupervisor` continues to work unchanged.** Every existing test stays green.

**Files:**
- Create: `Sources/AnglesiteCore/InProcessBackend.swift`
- Modify: `Sources/AnglesiteCore/ProcessSupervisor.swift`

- [ ] **Step 1: Read the existing `ProcessSupervisor.swift` end to end.**

You need every method, every nested type, every `private static func`. Take notes on the public API surface — `run(...)`, `launch(...)`, `terminate(_:)`, `shutdownAll(...)`, `stdinWriter(_:)`, `waitForExit(_:)`, `isRunning(_:)`, and the public types `RunResult`, `Handle`, `StdinHandle`, `SupervisorError`, `RestartPolicy`, `ExitReason`, `RespawnHandler`.

The refactor preserves the public API. Callers (`AstroDevServer`, `MCPClient`, etc.) don't need to change.

- [ ] **Step 2: Create `Sources/AnglesiteCore/InProcessBackend.swift`.**

Move the **implementation** of the spawn loop, `Entry` struct, `startProcess(for:)`, `superviseLoop(id:)`, and the readability/log-drain plumbing into this file. The public `SupervisorBackend` methods (`runOneShot`, `launch`, `terminate`, `shutdownAll`, `writeStdin`) are the only callable surface from outside.

The file is around 400 lines (mostly a direct move from `ProcessSupervisor`). Top of the file:

```swift
import Foundation

/// DevID backend: spawns processes directly via `Process()`. No sandbox; no XPC.
///
/// All the long-running supervision state (`Entry`, restart policy, log draining, stdin pipe)
/// previously lived in `ProcessSupervisor`. The actor stays — concurrent spawns mutate
/// `entries` and that mutation must be serialized.
public actor InProcessBackend: SupervisorBackend {
    private var entries: [UUID: Entry] = [:]
    private let logCenter: LogCenter

    public init(logCenter: LogCenter = .shared) {
        self.logCenter = logCenter
    }

    // MARK: SupervisorBackend

    public func runOneShot(_ spec: SpawnSpec) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        if let env = spec.environment { process.environment = env }
        if let cwd = spec.workingDirectory { process.currentDirectoryURL = cwd }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw SupervisorBackendError.spawnFailed(String(describing: error))
        }

        async let stdoutData = Self.readToEnd(stdoutPipe)
        async let stderrData = Self.readToEnd(stderrPipe)
        let (out, err) = await (stdoutData, stderrData)
        process.waitUntilExit()

        return ProcessResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }

    // …launch, terminate, shutdownAll, writeStdin — move from ProcessSupervisor verbatim,
    //   adapting parameter names to match SupervisorBackend. The supervision-loop logic
    //   (restart policy, Entry, log draining) all stays in this file, private.

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await Task.detached(priority: .userInitiated) {
            (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        }.value
    }
}
```

For `launch`, `terminate`, `shutdownAll`, `writeStdin`, and the private supervision internals: copy them from the current `ProcessSupervisor.swift` body, mechanically renaming function signatures to match `SupervisorBackend`. The `Entry` class, `startProcess`, `superviseLoop`, `resumeCancelledWaiter`, and `Self.readToEnd` all move into this file as `private`.

The mapping from old `ProcessSupervisor` to new `InProcessBackend`:

| Old name | New name | Notes |
|---|---|---|
| `run(executable:arguments:environment:)` | `runOneShot(_ spec: SpawnSpec)` | Read params out of `spec`. |
| `launch(source:executable:arguments:environment:currentDirectoryURL:restartPolicy:attachStdin:onRespawn:logCenter:)` | `launch(_ spec: SpawnSpec)` | `source` → `spec.logSource`, etc. `restartPolicy` / `onRespawn` are not in `SpawnSpec` — keep them in `Entry` initialized from defaults; if a caller needs them, they reach the backend via `ProcessSupervisor.launch(...)` (the facade still takes those params and forwards). |
| `terminate(_ handle: Handle, timeout:)` | `terminate(_ handle: SpawnedProcessHandle, timeout:)` | `Handle` → `SpawnedProcessHandle` (same UUID-based identity). |
| `shutdownAll(timeout:)` | same | unchanged behavior. |
| `stdinWriter(_:)` | `writeStdin(_:_:)` | callers move from "give me a `FileHandle`" to "send these bytes." See Step 4 for `MCPClient` migration. |

**Important:** `RestartPolicy` and `onRespawn: RespawnHandler` are not in `SpawnSpec` — they're not Codable (closures aren't). They live on `ProcessSupervisor.launch(...)`'s parameter list and the supervisor passes them to the backend out-of-band. Concretely: `InProcessBackend.launch(_:)` takes the spec; for in-process the supervisor *also* maintains restart policy + onRespawn keyed by handle, and calls `launch` again on crash. (Restart policy for the XPC backend lives in Task 6's design notes — out of scope here.)

- [ ] **Step 3: Refactor `ProcessSupervisor.swift` to a facade.**

The actor stays (callers use `ProcessSupervisor.shared`); the body shrinks dramatically. New body:

```swift
import Foundation

public actor ProcessSupervisor {
    public static let shared = ProcessSupervisor()

    private let backend: SupervisorBackend

    // Restart policy + onRespawn live here because closures aren't Codable.
    // Keyed by SpawnedProcessHandle.id.
    private var policies: [UUID: RestartPolicy] = [:]
    private var respawnHandlers: [UUID: RespawnHandler] = [:]

    public init(backend: SupervisorBackend? = nil) {
        if let backend {
            self.backend = backend
        } else {
            #if ANGLESITE_MAS
            self.backend = XPCBackend()
            #else
            self.backend = InProcessBackend()
            #endif
        }
    }

    // MARK: - Existing public API, preserved

    public struct RunResult: Sendable, Equatable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        // … unchanged
    }

    public typealias RespawnHandler = @Sendable () async -> Void

    public enum RestartPolicy: Sendable, Equatable {
        case never
        case onCrash(maxAttempts: Int, baseBackoff: TimeInterval)
    }

    public enum ExitReason: Sendable, Equatable { /* unchanged */ }

    public struct Handle: Sendable, Identifiable, Hashable {
        public let id: UUID
        public let source: String
        // Internal: paired SpawnedProcessHandle.id is the same UUID.
    }

    public func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> RunResult {
        let spec = SpawnSpec(
            executable: executable,
            arguments: arguments,
            environment: environment,
            logSource: "run:\(executable.lastPathComponent)"
        )
        let result = try await backend.runOneShot(spec)
        return RunResult(
            stdout: String(data: result.stdout, encoding: .utf8) ?? "",
            stderr: String(data: result.stderr, encoding: .utf8) ?? "",
            exitCode: result.exitCode
        )
    }

    @discardableResult
    public func launch(
        source: String,
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        restartPolicy: RestartPolicy = .never,
        attachStdin: Bool = false,
        onRespawn: RespawnHandler? = nil,
        logCenter: LogCenter = .shared
    ) async throws -> Handle {
        let spec = SpawnSpec(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: currentDirectoryURL,
            workingDirectoryBookmark: nil,  // populated by SiteWindow in MAS; nil here
            stdinPipe: attachStdin,
            logSource: source
        )
        let backendHandle = try await backend.launch(spec)
        let handle = Handle(id: backendHandle.id, source: source)
        policies[backendHandle.id] = restartPolicy
        if let onRespawn { respawnHandlers[backendHandle.id] = onRespawn }
        // Restart-policy enforcement: a small Task here observes the backend handle
        // and re-launches with the same spec on crash, calling onRespawn. (See
        // implementation note below.)
        return handle
    }

    public func terminate(_ handle: Handle, timeout: TimeInterval = 5) async {
        await backend.terminate(SpawnedProcessHandle(id: handle.id, pid: 0), timeout: timeout)
    }

    public func shutdownAll(timeout: TimeInterval = 5) async {
        await backend.shutdownAll(timeout: timeout)
    }

    public func stdinWriter(_ handle: Handle) -> StdinHandle? {
        // Returns a token wrapping the handle; the actual write goes through
        // backend.writeStdin in MCPClient.
        StdinHandle(handleID: handle.id)
    }

    public struct StdinHandle: Sendable {
        public let handleID: UUID
        // MCPClient's writer changes to call ProcessSupervisor.shared.writeStdin(_:_:) instead
        // of using a raw FileHandle.write(_:). See Step 4 below for the call-site update.
    }

    public func writeStdin(_ handle: StdinHandle, _ bytes: Data) async throws {
        try await backend.writeStdin(SpawnedProcessHandle(id: handle.handleID, pid: 0), bytes)
    }
}
```

Restart-policy + onRespawn for the XPC backend: deferred to Task 6. For now the InProcessBackend keeps the restart-loop logic internally and exposes a hook the supervisor can use to learn about crashes; the supervisor calls `respawnHandlers[id]` after a successful respawn. (The exact wiring is a copy of what's in the current `ProcessSupervisor.superviseLoop`, moved into `InProcessBackend` and exposing the same `onRespawn` semantics — the supervisor's restart-policy storage becomes vestigial for in-process and is only consulted by `XPCBackend` in Task 6.)

If the wiring of `onRespawn` between `ProcessSupervisor` and `InProcessBackend` gets messy, the simplest clean version is: `SupervisorBackend.launch(_:)` gains an `onRespawn: RespawnHandler? = nil` parameter at protocol level (closures aren't Codable but neither is the protocol method — only `SpawnSpec` itself needs Codable for XPC). This is a small extension of the protocol from Task 2; if you take that route, also add `restartPolicy: RestartPolicy = .never` to the protocol method. **Recommended:** do this. It keeps `InProcessBackend` self-contained and matches how `XPCBackend` will need to model it anyway.

- [ ] **Step 4: Update `MCPClient` (and any other caller using `stdinWriter`).**

Search for callers:

```sh
grep -rn "stdinWriter" Sources --include='*.swift'
```

Each caller currently does something like `writer.write(jsonRPC bytes)`. Change to:

```swift
let stdinHandle = await ProcessSupervisor.shared.stdinWriter(handle)
guard let stdinHandle else { throw … }
try await ProcessSupervisor.shared.writeStdin(stdinHandle, bytes)
```

(`MCPClient` is the only known caller; verify with the grep.)

- [ ] **Step 5: Build the DevID target.**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Run the full test suite.**

```sh
swift test --package-path . 2>&1 | tail -10
```

Expected: every existing test still passes. `ProcessSupervisorTests` (the pre-existing one) covers the supervisor's public API — if they fail, the facade isn't preserving behavior.

- [ ] **Step 7: Run the existing DevID smoke fixture.**

```sh
scripts/create-smoke-fixture.sh 2>&1 | tail -20
```

Expected: full pass — dev server starts, edit overlay drops in, MCP traffic round-trips, deploy preflight passes. (No actual deploy.)

- [ ] **Step 8: Commit.**

```sh
git add Sources/AnglesiteCore/SupervisorBackend.swift Sources/AnglesiteCore/InProcessBackend.swift Sources/AnglesiteCore/ProcessSupervisor.swift Sources/AnglesiteCore/MCPClient.swift Anglesite.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): split ProcessSupervisor into InProcessBackend + facade

Phase 10.1 prep. Moves the existing spawn/supervise loop into
InProcessBackend (DevID-only; uses Process() directly), and turns
ProcessSupervisor into a thin facade over a SupervisorBackend. All
public API of ProcessSupervisor is preserved — every existing caller
(AstroDevServer, MCPClient, DeployCommand, HealthModel, etc.)
continues to work without changes.

Behavior unchanged: full test suite passes, smoke fixture passes, the
DevID build is bit-for-bit equivalent to pre-refactor at the
ProcessSupervisor API surface.

MCPClient.stdinWriter path migrates from raw FileHandle.write to
ProcessSupervisor.writeStdin(_:_:) — the indirection is a no-op for
DevID and becomes the XPC bridge in Task 6.

Phase 10.1 Task 3 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: XPC protocol definitions (`AnglesiteHelperProtocol`)

**Files:**
- Create: `Sources/AnglesiteCore/XPC/AnglesiteHelperProtocol.swift`

- [ ] **Step 1: Create the file.**

```swift
import Foundation

/// XPC interface implemented by `AnglesiteHelper` and called from `XPCBackend` (the MAS app side).
///
/// All payloads cross the XPC boundary as `Data` containing JSON-encoded `SpawnSpec` /
/// `ProcessResult` / `SpawnedProcessHandle`. Keeping the `@objc` surface minimal means the
/// generated proxy stubs are predictable; richer types stay in Swift on both sides.
@objc public protocol AnglesiteHelperProtocol {
    /// One-shot spawn. `specData` is `JSONEncoder().encode(SpawnSpec)`.
    /// Reply `resultData` is `JSONEncoder().encode(ProcessResult)`, or `nil` if `error` is set.
    func runOneShot(specData: Data, reply: @escaping (Data?, Error?) -> Void)

    /// Long-lived spawn. Same encoding as `runOneShot` for the spec; reply is
    /// `JSONEncoder().encode(SpawnedProcessHandle)`. Stdout/stderr arrive on the client's
    /// `HelperClientProtocol` interface (registered via `NSXPCConnection.exportedObject`).
    func launch(specData: Data, reply: @escaping (Data?, Error?) -> Void)

    /// SIGTERM -> SIGKILL after `timeout`. `handleData` is the encoded `SpawnedProcessHandle`.
    func terminate(handleData: Data, timeout: TimeInterval, reply: @escaping () -> Void)

    /// Stop every process this helper instance is tracking. Called on connection
    /// invalidation as part of teardown.
    func shutdownAll(timeout: TimeInterval, reply: @escaping () -> Void)

    /// Write `bytes` to the spawned process's stdin. Throws (via `error`) if the spawn
    /// didn't set `stdinPipe: true`.
    func writeStdin(handleData: Data, bytes: Data, reply: @escaping (Error?) -> Void)
}

/// Inbound interface the helper calls back into the app for streaming events.
/// Registered on the `NSXPCConnection` via `exportedInterface` + `exportedObject` on the app side.
@objc public protocol HelperClientProtocol {
    /// A line of stdout from a spawned process. `pid` identifies which child; `source` is the
    /// `SpawnSpec.logSource` for tag routing into `LogCenter`.
    func stdoutLine(_ line: String, pid: Int32, source: String)

    /// Same shape for stderr.
    func stderrLine(_ line: String, pid: Int32, source: String)

    /// Process has exited. Final code; the supervisor uses this to resume `waitForExit`.
    /// `handleID` is the `SpawnedProcessHandle.id` UUID encoded as a string (XPC `@objc`
    /// can't pass `UUID` directly).
    func processExited(handleID: String, status: Int32)
}

/// XPC service name. Matches `CFBundleIdentifier` of `AnglesiteHelper.xpc/Contents/Info.plist`.
public let kAnglesiteHelperServiceName = "dev.anglesite.app.mas.helper"
```

- [ ] **Step 2: Make sure the file is picked up by both targets in `project.yml`.**

`Sources/AnglesiteCore` is already in the source list for both `Anglesite` and `AnglesiteMAS`. The XPC subdirectory needs no separate entry — `xcodegen` recurses. Verify by regenerating and inspecting the produced .pbxproj groups:

```sh
xcodegen generate
grep -c "AnglesiteHelperProtocol.swift" Anglesite.xcodeproj/project.pbxproj
```

Expected: at least 2 references (one per target).

- [ ] **Step 3: Build both targets.**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -5
```

Expected: both succeed.

- [ ] **Step 4: Commit.**

```sh
git add Sources/AnglesiteCore/XPC/AnglesiteHelperProtocol.swift Anglesite.xcodeproj
git commit -m "$(cat <<'EOF'
feat(core): AnglesiteHelperProtocol — XPC interface definitions

Shared @objc protocols for the MAS XPC service:
  - AnglesiteHelperProtocol: app → helper (spawn, terminate, shutdown, stdin)
  - HelperClientProtocol: helper → app (stdout/stderr/exit streaming)

All structured payloads cross the boundary as JSON-encoded SpawnSpec /
ProcessResult / SpawnedProcessHandle so the @objc surface stays
minimal and the rich Swift types stay in pure Swift on both sides.

No callers yet — the helper (Task 5) implements one side, XPCBackend
(Task 6) implements the other.

Phase 10.1 Task 4 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Build the `AnglesiteHelper` XPC service target (spawn works end-to-end inside helper)

**Files:**
- Create: `Sources/AnglesiteHelper/main.swift`
- Create: `Sources/AnglesiteHelper/HelperService.swift`
- Create: `Resources/AnglesiteHelper.entitlements`
- Create: `Resources/AnglesiteHelper-Info.plist`
- Modify: `project.yml`

- [ ] **Step 1: Add `Resources/AnglesiteHelper.entitlements`.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- XPC service: sandbox on (required when the host is sandboxed). -->
    <key>com.apple.security.app-sandbox</key><true/>

    <!-- Child processes inherit this sandbox profile. -->
    <key>com.apple.security.inherit</key><true/>

    <!-- Astro dev binds localhost. -->
    <key>com.apple.security.network.server</key><true/>

    <!-- wrangler deploys to Cloudflare; git push reaches GitHub. -->
    <key>com.apple.security.network.client</key><true/>

    <!-- Open the site folder via the security-scoped bookmark forwarded from the app. -->
    <key>com.apple.security.files.user-selected.read-write</key><true/>

    <!-- Node V8 needs JIT. App Store-compatible (unlike disable-library-validation). -->
    <key>com.apple.security.cs.allow-jit</key><true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: Add `Resources/AnglesiteHelper-Info.plist`.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>

    <!-- One service instance per connection; tied to the lifetime of the calling app. -->
    <key>XPCService</key>
    <dict>
        <key>ServiceType</key>
        <string>Application</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 3: Add the helper target to `project.yml`.**

Insert under `targets:`, after the `AnglesiteMAS:` block:

```yaml
  AnglesiteHelper:
    type: xpc-service
    platform: macOS
    sources:
      - path: Sources/AnglesiteHelper
      - path: Sources/AnglesiteCore/XPC      # shares the @objc protocol with the app
      - path: Sources/AnglesiteCore/SupervisorBackend.swift  # SpawnSpec / ProcessResult shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.anglesite.app.mas.helper
        PRODUCT_NAME: AnglesiteHelper
        INFOPLIST_FILE: Resources/AnglesiteHelper-Info.plist
        GENERATE_INFOPLIST_FILE: NO
        CODE_SIGN_ENTITLEMENTS: Resources/AnglesiteHelper.entitlements
        ENABLE_HARDENED_RUNTIME: YES
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        SWIFT_VERSION: "5.10"
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: "0.1.0"
      configs:
        Debug:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Apple Development"
        Release:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Apple Distribution"
```

Add the helper as an embedded dependency of `AnglesiteMAS:` — modify the `AnglesiteMAS:` block's `dependencies:` list:

```yaml
    dependencies:
      - package: Anglesite
        product: AnglesiteCore
      - package: Anglesite
        product: AnglesiteBridge
      - target: AnglesiteHelper
        embed: true
        codeSign: true
```

`xcodegen` puts embedded XPC services at `$(CONTENTS_FOLDER_PATH)/XPCServices/` by default — that's what we want.

- [ ] **Step 4: Create `Sources/AnglesiteHelper/main.swift`.**

```swift
import Foundation

/// XPC service entry point. `NSXPCListener.service()` returns the launchd-provided listener
/// for this process; everything else is wired up in `HelperListenerDelegate`.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: AnglesiteHelperProtocol.self)
        newConnection.remoteObjectInterface = NSXPCInterface(with: HelperClientProtocol.self)

        let service = HelperService(connection: newConnection)
        newConnection.exportedObject = service

        newConnection.invalidationHandler = { [weak service] in
            Task { await service?.connectionInvalidated() }
        }
        newConnection.interruptionHandler = { [weak service] in
            Task { await service?.connectionInvalidated() }
        }

        newConnection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
```

- [ ] **Step 5: Create `Sources/AnglesiteHelper/HelperService.swift`.**

```swift
import Foundation

/// One `HelperService` per `NSXPCConnection`. Owns the spawned child processes for that
/// connection. Connection teardown calls `shutdownAll` so no orphan children survive the app.
actor HelperService: NSObject {
    private let connection: NSXPCConnection
    private var children: [UUID: ChildProcess] = [:]

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// Streaming proxy back to the app. Lazily resolved on first use.
    private var clientProxy: HelperClientProtocol? {
        connection.remoteObjectProxyWithErrorHandler { error in
            // Connection died mid-stream. Cleanup is driven by invalidationHandler in main.swift.
        } as? HelperClientProtocol
    }

    func connectionInvalidated() async {
        await shutdownAll(timeout: 2)
    }

    /// Decode a SpawnSpec and prep the Process. Resolving the bookmark (if any) lives here.
    private func resolveSpawn(_ spec: SpawnSpec) throws -> (Process, URL?) {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        if let env = spec.environment { process.environment = env }

        var scopedURL: URL? = nil
        if let bookmark = spec.workingDirectoryBookmark {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw NSError(
                    domain: "AnglesiteHelper",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "bookmark resolution failed"]
                )
            }
            scopedURL = url
            process.currentDirectoryURL = url
        } else if let cwd = spec.workingDirectory {
            process.currentDirectoryURL = cwd
        }

        return (process, scopedURL)
    }

    // MARK: - AnglesiteHelperProtocol (via objc shim — see end of file)

    func runOneShotImpl(specData: Data) async throws -> Data {
        let spec = try JSONDecoder().decode(SpawnSpec.self, from: specData)
        let (process, scopedURL) = try resolveSpawn(spec)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        async let outData = Task.detached { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }.value
        async let errData = Task.detached { stderrPipe.fileHandleForReading.readDataToEndOfFile() }.value
        let (out, err) = await (outData, errData)
        process.waitUntilExit()

        scopedURL?.stopAccessingSecurityScopedResource()

        let result = ProcessResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
        return try JSONEncoder().encode(result)
    }

    func launchImpl(specData: Data) async throws -> Data {
        let spec = try JSONDecoder().decode(SpawnSpec.self, from: specData)
        let (process, scopedURL) = try resolveSpawn(spec)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdinFH: FileHandle? = nil
        if spec.stdinPipe {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinFH = stdinPipe.fileHandleForWriting
        }

        try process.run()
        let pid = process.processIdentifier
        let handle = SpawnedProcessHandle(pid: pid)

        let child = ChildProcess(
            id: handle.id,
            process: process,
            stdinFH: stdinFH,
            scopedURL: scopedURL,
            source: spec.logSource
        )
        children[handle.id] = child

        // Stream stdout/stderr line-by-line via the client proxy.
        child.startStreaming(
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            proxy: clientProxy,
            onExit: { [weak self] code in
                Task { await self?.reapChild(id: handle.id, exitCode: code) }
            }
        )

        return try JSONEncoder().encode(handle)
    }

    private func reapChild(id: UUID, exitCode: Int32) async {
        guard let child = children.removeValue(forKey: id) else { return }
        child.scopedURL?.stopAccessingSecurityScopedResource()
        clientProxy?.processExited(handleID: id.uuidString, status: exitCode)
    }

    func terminateImpl(handleData: Data, timeout: TimeInterval) async {
        guard let handle = try? JSONDecoder().decode(SpawnedProcessHandle.self, from: handleData),
              let child = children[handle.id] else { return }
        child.process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while child.process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if child.process.isRunning {
            kill(child.process.processIdentifier, SIGKILL)
        }
    }

    func shutdownAll(timeout: TimeInterval) async {
        let snapshot = Array(children.values)
        await withTaskGroup(of: Void.self) { group in
            for child in snapshot {
                group.addTask {
                    child.process.terminate()
                    let deadline = Date().addingTimeInterval(timeout)
                    while child.process.isRunning && Date() < deadline {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if child.process.isRunning {
                        kill(child.process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        for (id, child) in children {
            child.scopedURL?.stopAccessingSecurityScopedResource()
            children.removeValue(forKey: id)
        }
    }

    func writeStdinImpl(handleData: Data, bytes: Data) async throws {
        let handle = try JSONDecoder().decode(SpawnedProcessHandle.self, from: handleData)
        guard let child = children[handle.id], let fh = child.stdinFH else {
            throw NSError(
                domain: "AnglesiteHelper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no stdin pipe for this handle"]
            )
        }
        try fh.write(contentsOf: bytes)
    }
}

/// `NSXPCConnection` requires an `@objc` class as the `exportedObject`. The actor above does
/// the real work; this shim adapts the @objc reply-handler signature into async/await.
extension HelperService: AnglesiteHelperProtocol {
    nonisolated func runOneShot(specData: Data, reply: @escaping (Data?, Error?) -> Void) {
        Task {
            do { reply(try await runOneShotImpl(specData: specData), nil) }
            catch { reply(nil, error) }
        }
    }

    nonisolated func launch(specData: Data, reply: @escaping (Data?, Error?) -> Void) {
        Task {
            do { reply(try await launchImpl(specData: specData), nil) }
            catch { reply(nil, error) }
        }
    }

    nonisolated func terminate(handleData: Data, timeout: TimeInterval, reply: @escaping () -> Void) {
        Task { await terminateImpl(handleData: handleData, timeout: timeout); reply() }
    }

    nonisolated func shutdownAll(timeout: TimeInterval, reply: @escaping () -> Void) {
        Task { await shutdownAll(timeout: timeout); reply() }
    }

    nonisolated func writeStdin(handleData: Data, bytes: Data, reply: @escaping (Error?) -> Void) {
        Task {
            do { try await writeStdinImpl(handleData: handleData, bytes: bytes); reply(nil) }
            catch { reply(error) }
        }
    }
}

/// One spawned child's local bookkeeping. Lives only inside `HelperService.children`.
final class ChildProcess {
    let id: UUID
    let process: Process
    let stdinFH: FileHandle?
    let scopedURL: URL?
    let source: String

    init(id: UUID, process: Process, stdinFH: FileHandle?, scopedURL: URL?, source: String) {
        self.id = id
        self.process = process
        self.stdinFH = stdinFH
        self.scopedURL = scopedURL
        self.source = source
    }

    func startStreaming(
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        proxy: HelperClientProtocol?,
        onExit: @escaping (Int32) -> Void
    ) {
        let pid = process.processIdentifier
        let src = source

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                proxy?.stdoutLine(String(line), pid: pid, source: src)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                proxy?.stderrLine(String(line), pid: pid, source: src)
            }
        }

        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            onExit(proc.terminationStatus)
        }
    }
}
```

- [ ] **Step 6: Regenerate and build the helper.**

```sh
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -target AnglesiteHelper -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. If the build fails on `kAnglesiteHelperServiceName` or types from `SupervisorBackend.swift` not being visible — that's likely a `project.yml` sources-list mistake; re-check Step 3's `sources:` block (it must include `Sources/AnglesiteCore/XPC` *and* `Sources/AnglesiteCore/SupervisorBackend.swift`).

- [ ] **Step 7: Build the MAS app target (which now embeds the helper).**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. Verify the embed:

```sh
find ~/Library/Developer/Xcode/DerivedData/Anglesite-*/Build/Products/Debug/Anglesite.app/Contents/XPCServices -name "AnglesiteHelper.xpc" -type d 2>&1
```

Expected: one path printed.

- [ ] **Step 8: Run existing tests as a regression sweep.**

```sh
swift test --package-path . 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 9: Commit.**

```sh
git add Sources/AnglesiteHelper Resources/AnglesiteHelper.entitlements Resources/AnglesiteHelper-Info.plist project.yml Anglesite.xcodeproj
git commit -m "$(cat <<'EOF'
feat(mas): AnglesiteHelper XPC service — spawns under sandbox

Bundled into AnglesiteMAS.app/Contents/XPCServices/. Implements
AnglesiteHelperProtocol: decode SpawnSpec → resolve security-scoped
bookmark → Process() → stream stdout/stderr lines back to the app via
HelperClientProtocol → reap on exit.

One HelperService instance per NSXPCConnection; children tied to the
connection's lifetime so closing the connection (window close, app
quit) cleans up everything.

Helper compiles standalone and embeds correctly into AnglesiteMAS.app.
Not yet wired into ProcessSupervisor — that's Task 6 (XPCBackend).

Phase 10.1 Task 5 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `XPCBackend` — wire MAS app to the helper

**Files:**
- Create: `Sources/AnglesiteCore/XPCBackend.swift`
- Modify: `Sources/AnglesiteCore/ProcessSupervisor.swift` (the `#if ANGLESITE_MAS` branch)

- [ ] **Step 1: Create `Sources/AnglesiteCore/XPCBackend.swift`.**

```swift
#if ANGLESITE_MAS
import Foundation

/// MAS-only backend. One persistent `NSXPCConnection` to `AnglesiteHelper`. Created lazily on
/// the first spawn; invalidated on `shutdownAll`. The helper process is one per connection,
/// so closing the connection terminates every child the helper had spawned.
public actor XPCBackend: SupervisorBackend {
    private var connection: NSXPCConnection?
    /// Tracks every long-lived spawn so we can stream exits back to waiters.
    private var liveHandles: Set<UUID> = []
    /// Exit-code subscribers keyed by handle UUID, resolved by `HelperClientHandler` below.
    private var exitContinuations: [UUID: CheckedContinuation<Int32, Never>] = [:]

    public init() {}

    private func ensureConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        let new = NSXPCConnection(serviceName: kAnglesiteHelperServiceName)
        new.remoteObjectInterface = NSXPCInterface(with: AnglesiteHelperProtocol.self)
        new.exportedInterface = NSXPCInterface(with: HelperClientProtocol.self)
        new.exportedObject = HelperClientHandler(backend: self)
        new.invalidationHandler = { [weak self] in
            Task { await self?.connectionInvalidated() }
        }
        new.interruptionHandler = { [weak self] in
            Task { await self?.connectionInvalidated() }
        }
        new.resume()
        connection = new
        return new
    }

    private func connectionInvalidated() async {
        // Helper crashed or shutdown completed. Resolve any pending exit waiters with -1.
        for (_, cont) in exitContinuations {
            cont.resume(returning: -1)
        }
        exitContinuations.removeAll()
        liveHandles.removeAll()
        connection = nil
    }

    /// Called by `HelperClientHandler` when the helper reports a process exit.
    func recordExit(handleID: UUID, status: Int32) {
        liveHandles.remove(handleID)
        if let cont = exitContinuations.removeValue(forKey: handleID) {
            cont.resume(returning: status)
        }
    }

    // MARK: SupervisorBackend

    public func runOneShot(_ spec: SpawnSpec) async throws -> ProcessResult {
        let conn = try ensureConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in } as? AnglesiteHelperProtocol
        guard let proxy else {
            throw SupervisorBackendError.backendUnavailable("XPC proxy not available")
        }
        let specData = try JSONEncoder().encode(spec)
        return try await withCheckedThrowingContinuation { cont in
            proxy.runOneShot(specData: specData) { data, error in
                if let error {
                    cont.resume(throwing: SupervisorBackendError.spawnFailed(error.localizedDescription))
                } else if let data, let result = try? JSONDecoder().decode(ProcessResult.self, from: data) {
                    cont.resume(returning: result)
                } else {
                    cont.resume(throwing: SupervisorBackendError.spawnFailed("decode failure"))
                }
            }
        }
    }

    public func launch(_ spec: SpawnSpec) async throws -> SpawnedProcessHandle {
        let conn = try ensureConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in } as? AnglesiteHelperProtocol
        guard let proxy else {
            throw SupervisorBackendError.backendUnavailable("XPC proxy not available")
        }
        let specData = try JSONEncoder().encode(spec)
        let handle: SpawnedProcessHandle = try await withCheckedThrowingContinuation { cont in
            proxy.launch(specData: specData) { data, error in
                if let error {
                    cont.resume(throwing: SupervisorBackendError.spawnFailed(error.localizedDescription))
                } else if let data, let h = try? JSONDecoder().decode(SpawnedProcessHandle.self, from: data) {
                    cont.resume(returning: h)
                } else {
                    cont.resume(throwing: SupervisorBackendError.spawnFailed("decode failure"))
                }
            }
        }
        liveHandles.insert(handle.id)
        return handle
    }

    public func terminate(_ handle: SpawnedProcessHandle, timeout: TimeInterval) async {
        guard let conn = connection,
              let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in }) as? AnglesiteHelperProtocol,
              let handleData = try? JSONEncoder().encode(handle)
        else { return }
        await withCheckedContinuation { cont in
            proxy.terminate(handleData: handleData, timeout: timeout) { cont.resume() }
        }
    }

    public func shutdownAll(timeout: TimeInterval) async {
        guard let conn = connection,
              let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in }) as? AnglesiteHelperProtocol
        else { return }
        await withCheckedContinuation { cont in
            proxy.shutdownAll(timeout: timeout) { cont.resume() }
        }
        conn.invalidate()
        connection = nil
    }

    public func writeStdin(_ handle: SpawnedProcessHandle, _ bytes: Data) async throws {
        guard let conn = connection,
              let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in }) as? AnglesiteHelperProtocol
        else {
            throw SupervisorBackendError.backendUnavailable("no XPC connection")
        }
        let handleData = try JSONEncoder().encode(handle)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.writeStdin(handleData: handleData, bytes: bytes) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}

/// Receives stdout/stderr/exit callbacks from the helper and routes them to LogCenter / waiters.
final class HelperClientHandler: NSObject, HelperClientProtocol {
    let backend: XPCBackend

    init(backend: XPCBackend) {
        self.backend = backend
    }

    func stdoutLine(_ line: String, pid: Int32, source: String) {
        Task { await LogCenter.shared.append(source: source, line: line, stream: .stdout) }
    }

    func stderrLine(_ line: String, pid: Int32, source: String) {
        Task { await LogCenter.shared.append(source: source, line: line, stream: .stderr) }
    }

    func processExited(handleID: String, status: Int32) {
        guard let uuid = UUID(uuidString: handleID) else { return }
        Task { await backend.recordExit(handleID: uuid, status: status) }
    }
}
#endif
```

The `LogCenter.append(source:line:stream:)` signature here must match what `LogCenter` actually exposes — check `Sources/AnglesiteCore/LogCenter.swift` and adapt the calls if the param names differ.

- [ ] **Step 2: Wire `ProcessSupervisor` to pick `XPCBackend` under `#if ANGLESITE_MAS`.**

This was scaffolded in Task 3 already (the `#if ANGLESITE_MAS` branch of `init`). Confirm it reads exactly:

```swift
public init(backend: SupervisorBackend? = nil) {
    if let backend {
        self.backend = backend
    } else {
        #if ANGLESITE_MAS
        self.backend = XPCBackend()
        #else
        self.backend = InProcessBackend()
        #endif
    }
}
```

No change unless Task 3 left this stubbed differently.

- [ ] **Step 3: Build the MAS scheme.**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. The MAS app at this point can connect to the helper, but won't actually drive a useful flow until bookmark plumbing lands (Task 7).

- [ ] **Step 4: Build the DevID scheme.**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. The DevID build does *not* compile `XPCBackend.swift` (entire file is under `#if ANGLESITE_MAS`).

- [ ] **Step 5: Full test suite + DevID smoke.**

```sh
swift test --package-path . 2>&1 | tail -5
scripts/create-smoke-fixture.sh 2>&1 | tail -10
```

Expected: all green.

- [ ] **Step 6: Commit.**

```sh
git add Sources/AnglesiteCore/XPCBackend.swift Sources/AnglesiteCore/ProcessSupervisor.swift Anglesite.xcodeproj
git commit -m "$(cat <<'EOF'
feat(mas): XPCBackend — ProcessSupervisor backend for the MAS build

NSXPCConnection to AnglesiteHelper. One persistent connection per
ProcessSupervisor lifetime; the helper process is one per connection,
so connection invalidation reaps every child. Stdout/stderr lines
arrive via HelperClientProtocol and route into LogCenter unchanged
from the DevID path.

DevID build does not compile XPCBackend.swift (entire file under
#if ANGLESITE_MAS). Regression: full test suite + DevID smoke fixture
green.

Bookmark plumbing comes next (Task 7) — until then the MAS app can
connect to the helper but no actual site flow works because the
working-directory bookmark is nil and the helper can't enter the
site folder.

Phase 10.1 Task 6 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Security-scoped bookmarks in `SiteStore` + open flow

**Goal:** `SiteStore.Site` gains a `bookmarkData` field. The "open folder" flow creates the bookmark; every subsequent open resolves and `startAccessingSecurityScopedResource()`s. The bookmark bytes are threaded into every `SpawnSpec` headed to the helper.

**Files:**
- Create: `Sources/AnglesiteCore/SecurityScopedBookmark.swift`
- Create: `Tests/AnglesiteCoreTests/SecurityScopedBookmarkTests.swift`
- Modify: `Sources/AnglesiteCore/SiteStore.swift` (add `bookmarkData: Data?` to `Site`)
- Modify: callers that create `SpawnSpec` (i.e., `ProcessSupervisor.launch(...)`) to thread the bookmark through

- [ ] **Step 1: Write the failing test.**

`Tests/AnglesiteCoreTests/SecurityScopedBookmarkTests.swift`:

```swift
import XCTest
@testable import AnglesiteCore

final class SecurityScopedBookmarkTests: XCTestCase {
    /// On non-sandboxed test runs, bookmarks created with .withSecurityScope still produce
    /// resolvable Data; they just don't actually scope anything. That's enough to verify the
    /// create/resolve round-trip on the SPM test runner.
    func test_create_and_resolve_roundTrip() throws {
        let tmp = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "/tmp"),
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bookmark = try SecurityScopedBookmark.create(for: tmp)
        XCTAssertFalse(bookmark.isEmpty)

        let resolved = try SecurityScopedBookmark.resolve(bookmark)
        XCTAssertEqual(resolved.url.path, tmp.path)
        XCTAssertFalse(resolved.isStale)
    }

    func test_resolve_corruptData_throws() {
        let garbage = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertThrowsError(try SecurityScopedBookmark.resolve(garbage))
    }
}
```

- [ ] **Step 2: Run to verify fails.**

```sh
swift test --package-path . --filter SecurityScopedBookmarkTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find 'SecurityScopedBookmark' in scope`.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/SecurityScopedBookmark.swift`.**

```swift
import Foundation

/// Wrapper around `URL.bookmarkData(options: .withSecurityScope, ...)` so app and helper share
/// the same create/resolve logic. The bookmark is persisted as `Data` on `SiteStore.Site`.
public enum SecurityScopedBookmark {
    public struct Resolved {
        public let url: URL
        public let isStale: Bool
    }

    public enum BookmarkError: Error, Sendable {
        case createFailed(String)
        case resolveFailed(String)
    }

    /// Create a security-scoped bookmark for `url`. The caller is responsible for having
    /// access at create time (typically: just returned from `NSOpenPanel`).
    public static func create(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BookmarkError.createFailed(error.localizedDescription)
        }
    }

    /// Resolve a previously-created bookmark. Caller must `startAccessingSecurityScopedResource()`
    /// on the returned URL before use, and `stopAccessingSecurityScopedResource()` when done.
    public static func resolve(_ data: Data) throws -> Resolved {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return Resolved(url: url, isStale: isStale)
        } catch {
            throw BookmarkError.resolveFailed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Add `bookmarkData: Data?` to `SiteStore.Site` and persist it.**

In `Sources/AnglesiteCore/SiteStore.swift`, modify the `Site` struct:

```swift
public struct Site: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let path: URL
    public var isValid: Bool
    public var missingSentinels: [String]
    public var lastSeen: Date
    /// Security-scoped bookmark for `path`. Populated on first add via NSOpenPanel in MAS;
    /// `nil` for DevID (no sandbox) and for sites discovered by directory scan (which can't
    /// create a bookmark without the user explicitly granting access).
    public var bookmarkData: Data?

    public init(
        id: String,
        name: String,
        path: URL,
        isValid: Bool,
        missingSentinels: [String],
        lastSeen: Date,
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isValid = isValid
        self.missingSentinels = missingSentinels
        self.lastSeen = lastSeen
        self.bookmarkData = bookmarkData
    }
}
```

`Codable` synthesis handles the new field automatically; existing `sites.json` files without the key decode with `bookmarkData == nil` (the property is optional).

Add a method to set the bookmark:

```swift
extension SiteStore {
    /// Stamp `bookmarkData` onto the site with the given id, then persist.
    public func setBookmark(_ data: Data, for id: String) async throws {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[index].bookmarkData = data
        try persist()
    }
}
```

(`persist()` is the existing private write-to-`sites.json` method; if its name differs, adapt.)

- [ ] **Step 5: Plumb bookmark into `SpawnSpec` via `ProcessSupervisor.launch(...)`.**

`ProcessSupervisor.launch(...)` gains an optional `workingDirectoryBookmark: Data? = nil` parameter (purely additive — DevID callers don't pass it, behavior unchanged):

```swift
public func launch(
    source: String,
    executable: URL,
    arguments: [String] = [],
    environment: [String: String]? = nil,
    currentDirectoryURL: URL? = nil,
    workingDirectoryBookmark: Data? = nil,   // new
    restartPolicy: RestartPolicy = .never,
    attachStdin: Bool = false,
    onRespawn: RespawnHandler? = nil,
    logCenter: LogCenter = .shared
) async throws -> Handle {
    let spec = SpawnSpec(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: currentDirectoryURL,
        workingDirectoryBookmark: workingDirectoryBookmark,  // new
        stdinPipe: attachStdin,
        logSource: source
    )
    // … rest unchanged
}
```

Similarly add `workingDirectoryBookmark` to `ProcessSupervisor.run(...)`'s signature for symmetry.

- [ ] **Step 6: Update `AstroDevServer` (and `MCPClient.start`, and any other caller using a working-directory URL) to pass the bookmark.**

Find every call to `ProcessSupervisor.shared.launch(...)` that sets `currentDirectoryURL:` for a site folder. They all already have access to the site URL; the bookmark needs to come from the same place. Pattern:

```swift
// Before:
try await ProcessSupervisor.shared.launch(
    source: "astro:dev:\(siteID)",
    executable: nodeExe,
    arguments: ["…"],
    currentDirectoryURL: siteDir,
    …
)

// After:
let bookmark = await SiteStore.shared.bookmarkData(for: siteID)  // new helper, see below
try await ProcessSupervisor.shared.launch(
    source: "astro:dev:\(siteID)",
    executable: nodeExe,
    arguments: ["…"],
    currentDirectoryURL: siteDir,
    workingDirectoryBookmark: bookmark,
    …
)
```

Add the helper on `SiteStore`:

```swift
extension SiteStore {
    public func bookmarkData(for id: String) -> Data? {
        sites.first(where: { $0.id == id })?.bookmarkData
    }
}
```

For DevID, `bookmark` is `nil`, the `InProcessBackend` ignores it, and behavior is unchanged.

- [ ] **Step 7: Add the open-folder bookmark-create path in MAS launcher.**

In `Sources/AnglesiteApp/SitesLauncherView.swift` (or wherever "Open Folder…" is wired), after `NSOpenPanel` returns a URL, create the bookmark and persist:

```swift
#if ANGLESITE_MAS
let bookmark = try SecurityScopedBookmark.create(for: pickedURL)
// Whatever the existing add-site code path is, call setBookmark after the Site is added:
try await SiteStore.shared.setBookmark(bookmark, for: newSiteID)
#endif
```

(The exact integration point depends on the launcher's current code; the implementer subagent should grep for the existing "Open Folder…" handler and integrate at the natural seam.)

- [ ] **Step 8: Run the new tests.**

```sh
swift test --package-path . --filter SecurityScopedBookmarkTests 2>&1 | tail -10
```

Expected: 2 passed.

- [ ] **Step 9: Run full suite + DevID smoke.**

```sh
swift test --package-path . 2>&1 | tail -5
scripts/create-smoke-fixture.sh 2>&1 | tail -10
```

Expected: all green. The DevID build sees `bookmarkData: nil` on every site (no NSOpenPanel path used) and behavior is unchanged.

- [ ] **Step 10: Build both schemes.**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -3
```

Expected: both succeed.

- [ ] **Step 11: Commit.**

```sh
git add Sources/AnglesiteCore/SecurityScopedBookmark.swift Sources/AnglesiteCore/SiteStore.swift Sources/AnglesiteCore/ProcessSupervisor.swift Sources/AnglesiteCore/AstroDevServer.swift Sources/AnglesiteCore/MCPClient.swift Sources/AnglesiteApp/SitesLauncherView.swift Tests/AnglesiteCoreTests/SecurityScopedBookmarkTests.swift Anglesite.xcodeproj
git commit -m "$(cat <<'EOF'
feat(mas): security-scoped bookmarks threaded through SpawnSpec

SiteStore.Site gains `bookmarkData: Data?` (back-compat optional;
existing sites.json files decode with nil unchanged). MAS's
"Open Folder…" flow creates the bookmark via SecurityScopedBookmark
and stamps it onto the new site.

ProcessSupervisor.launch / .run gain an optional
workingDirectoryBookmark parameter that flows into SpawnSpec. DevID
callers don't pass it; behavior unchanged. MAS callers pull from
SiteStore.bookmarkData(for:) and pass through every launch.

Phase 10.1 Task 7 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Migrate direct `Process()` calls to `ProcessSupervisor`

**Goal:** The two remaining direct-`Process()` call sites (`DeployCommand:279`, `SettingsView:245`) currently bypass `ProcessSupervisor`. They work in DevID but break under sandbox. Route them through the supervisor so the XPC backend picks them up automatically.

**Files:**
- Modify: `Sources/AnglesiteCore/DeployCommand.swift:279`
- Modify: `Sources/AnglesiteApp/SettingsView.swift:245`

- [ ] **Step 1: Migrate `DeployCommand.swift:279`.**

Find the block (around line 279):

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
// … args, env, pipes, run, wait …
```

Replace with `ProcessSupervisor.run(...)`. The exact rewrite depends on what the surrounding logic does with stdout/stderr; preserve all of that. Pattern:

```swift
let bookmark = await SiteStore.shared.bookmarkData(for: siteID)  // siteID from the existing scope
let result = try await ProcessSupervisor.shared.run(
    executable: URL(fileURLWithPath: "/usr/bin/env"),
    arguments: existingArgs,
    environment: existingEnv,
    currentDirectoryURL: siteDir,
    workingDirectoryBookmark: bookmark
)
// existing code that consumed stdout/stderr/exitCode now reads from `result`
```

(If `ProcessSupervisor.run` doesn't currently take `currentDirectoryURL` — verify and add it; the symmetric extension was implied in Task 7 Step 5.)

- [ ] **Step 2: Migrate `SettingsView.swift:245`.**

The `gh auth status` block. Two changes here:

1. Route it through `ProcessSupervisor.run(...)` rather than direct `Process()`.
2. Wrap the entire `GitHubAuthSection` in `#if !ANGLESITE_MAS` (Task 10 makes the wrapping fully clean, but the surrounding `refreshStatus` method that uses the Process must be inside the conditional). For Task 8, leave the wrapping until Task 10 — just do the `ProcessSupervisor` migration here so DevID stays clean:

```swift
private func refreshStatus() async {
    guard let gh = ResolveBinary.locate("gh") else {
        status = .unavailable("`gh` not installed (brew install gh).")
        return
    }
    do {
        let result = try await ProcessSupervisor.shared.run(
            executable: gh,
            arguments: ["auth", "status", "--hostname", "github.com"]
        )
        if result.exitCode == 0 {
            // existing parse logic
        } else {
            status = .signedOut
        }
    } catch {
        status = .unavailable("couldn't run `gh`: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 3: Search for any other direct `Process()` calls.**

```sh
grep -rnE '(let|var)\s+\w+\s*=\s*Process\(\)' Sources --include='*.swift' | grep -v Test
```

Expected: only the two we just migrated (and `ProcessSupervisor.swift` / `InProcessBackend.swift` / `HelperService.swift` internally — those are the legitimate sites). If anything else shows up, migrate it the same way before continuing.

- [ ] **Step 4: Build both schemes.**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -3
```

Expected: both succeed.

- [ ] **Step 5: Run tests + DevID smoke.**

```sh
swift test --package-path . 2>&1 | tail -5
scripts/create-smoke-fixture.sh 2>&1 | tail -10
```

Expected: all green.

- [ ] **Step 6: Commit.**

```sh
git add Sources/AnglesiteCore/DeployCommand.swift Sources/AnglesiteApp/SettingsView.swift
git commit -m "$(cat <<'EOF'
refactor(core): route all Process() calls through ProcessSupervisor

The two remaining direct-Process() sites (DeployCommand:279 for the
wrangler/env shell-out, SettingsView:245 for `gh auth status`) now go
through ProcessSupervisor.run(...). In DevID this is a pure refactor
(InProcessBackend uses the same Process() under the hood). In MAS,
these calls now flow through XPCBackend → the helper → Process(),
which is the only spawn path allowed under the sandbox.

The `gh` call is wrapped in #if !ANGLESITE_MAS in Task 10 — for now
both builds compile it; MAS would fail to find `gh` on a real
sandboxed user's machine, but the call site is unreachable until the
Settings UI exposes it.

Phase 10.1 Task 8 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Compile chat out of MAS (`#if !ANGLESITE_MAS`)

**Files:**
- Modify: `Sources/AnglesiteApp/ChatModel.swift`
- Modify: `Sources/AnglesiteApp/ChatView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`
- Modify: `Sources/AnglesiteCore/ClaudeAgent.swift`

- [ ] **Step 1: Wrap each chat file in `#if !ANGLESITE_MAS`.**

For `ChatModel.swift`, `ChatView.swift`, `ClaudeAgent.swift`: insert at the very top (after the file's own `import` statements is fine, but the simplest is at line 1):

```swift
#if !ANGLESITE_MAS

// … entire existing file body unchanged …

#endif
```

(Imports inside the `#if` block work; Swift's parser tolerates them.)

- [ ] **Step 2: Wrap chat references in `SiteWindow.swift`.**

In `Sources/AnglesiteApp/SiteWindow.swift` (read it first — multiple chat sites):

- Wrap the `@State private var chat: ChatModel?` and `@State private var chatPresented = false` lines.
- Wrap the chat-button HStack block (around lines 112–122 of the version in this conversation summary).
- Wrap the `if chatPresented, let chat { Divider(); ChatView(model: chat) … }` block in `siteUI(for:)`.
- Wrap the `chat?.send(...)` calls inside `HealthBadgeView`'s `onAskClaude:` closure — replace with a no-op closure under `#if ANGLESITE_MAS`, or wrap the whole `onAskClaude` argument site.
- Wrap the chat-related lines in `loadAndStart()` (the `chat = ChatModel(...)` and `preview.setEditObserver { [weak chat] reply in …; chat?.recordEdit(reply) }` blocks).

Example pattern for the button:

```swift
#if !ANGLESITE_MAS
Button {
    chatPresented.toggle()
} label: {
    Label("Chat",
          systemImage: chatPresented
            ? "bubble.left.and.bubble.right.fill"
            : "bubble.left.and.bubble.right")
}
.controlSize(.small)
.help(chatPresented ? "Hide chat panel" : "Show chat panel")
.keyboardShortcut("k", modifiers: [.command])
#endif
```

For the `onAskClaude:` closure of `HealthBadgeView`:

```swift
HealthBadgeView(
    model: health,
    onRecheck: { health.recheck(siteID: site.id, siteDirectory: site.path) },
    onAskClaude: {
        #if !ANGLESITE_MAS
        chatPresented = true
        chat?.send("/anglesite:check")
        #endif
    }
)
```

(`HealthBadgeView` keeps the `onAskClaude` callback; in MAS it just hides the "Ask Claude" button in its own popover. That's a one-line follow-up in `HealthBadgeView` — wrap the "Ask Claude" button there in `#if !ANGLESITE_MAS` too.)

- [ ] **Step 3: Build both schemes.**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -3
```

Expected: both succeed. If MAS fails on a `chat?` reference that wasn't wrapped, fix and retry — the grep below catches stragglers:

```sh
grep -rn "chat\|ChatModel\|ClaudeAgent" Sources --include='*.swift' | grep -v "// " | grep -v "^[^:]*:.*#if" | head -30
```

Every match should be either inside a `#if !ANGLESITE_MAS` block, or in a file whose entire body is wrapped.

- [ ] **Step 4: Run tests.**

```sh
swift test --package-path . 2>&1 | tail -5
```

Expected: pass. Tests live in `Tests/AnglesiteCoreTests` and `Tests/AnglesiteAppTests` (if the latter exists); they're compiled against the DevID `ANGLESITE_MAS`-unset configuration, so chat tests stay live there.

- [ ] **Step 5: Sanity-check the MAS app launches.**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -3
# Find the built .app and launch it briefly to confirm no chat button appears
DERIVED=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "Anglesite-*" -type d | head -1)
open "$DERIVED/Build/Products/Debug/Anglesite.app"
# Visually verify in the launcher window: no Chat button, ⌘K does nothing.
# Then quit.
osascript -e 'tell application "Anglesite" to quit'
```

Expected: launcher window opens, no chat button visible.

- [ ] **Step 6: Commit.**

```sh
git add Sources/AnglesiteApp/ChatModel.swift Sources/AnglesiteApp/ChatView.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteCore/ClaudeAgent.swift Sources/AnglesiteApp/HealthBadgeView.swift
git commit -m "$(cat <<'EOF'
feat(mas): omit chat panel from MAS build (#if !ANGLESITE_MAS)

ChatModel, ChatView, ClaudeAgent are entirely wrapped — they don't
compile in the MAS target at all. SiteWindow's chat button, ⌘K
shortcut, ChatView mounting, and ChatModel state are all guarded.
HealthBadgeView's "Ask Claude" button is also hidden in MAS (the
underlying onAskClaude closure no-ops).

Chat returns in Phase 10.2 as a native Anthropic API client. The
plugin's MCP server still runs in MAS — the edit overlay flow is
unaffected.

Phase 10.1 Task 9 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Compile Sparkle + `gh` Settings panel out of MAS

**Files:**
- Modify: `Sources/AnglesiteApp/Updater.swift`
- Modify: `Sources/AnglesiteApp/SettingsView.swift`
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift` (or wherever Updater is constructed and the menu wired)

- [ ] **Step 1: Wrap `Updater.swift` in `#if !ANGLESITE_MAS`.**

```swift
#if !ANGLESITE_MAS
import SwiftUI
import Combine
import Sparkle

// … entire existing class body unchanged …
#endif
```

- [ ] **Step 2: Find every reference to `Updater` and wrap.**

```sh
grep -rn "Updater\|SPUStandardUpdaterController\|@StateObject.*updater\|.checkForUpdates" Sources --include='*.swift'
```

Common sites: `AnglesiteApp.swift` constructs an `Updater()` and a Menu Command for "Check for Updates…" Wrap them:

```swift
#if !ANGLESITE_MAS
@StateObject private var updater = Updater()
#endif

// In the .commands modifier:
CommandGroup(after: .appInfo) {
    #if !ANGLESITE_MAS
    Button("Check for Updates…") {
        updater.checkForUpdates()
    }
    .disabled(!updater.canCheckForUpdates)
    #endif
}
```

- [ ] **Step 3: Wrap `GitHubAuthSection` in `#if !ANGLESITE_MAS` and add the MAS replacement.**

In `Sources/AnglesiteApp/SettingsView.swift`, find the `GitHubAuthSection` view (or whatever the surrounding struct is called) and wrap the entire view definition:

```swift
#if !ANGLESITE_MAS
struct GitHubAuthSection: View {
    // … existing body unchanged …
}
#endif

#if ANGLESITE_MAS
struct GitHubAuthSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GitHub").font(.headline)
            HStack {
                Text("Anglesite uses your existing `git` credentials (macOS Keychain or SSH key).")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Link("Help", destination: URL(string: "https://anglesite.dev/help/mas-git-setup")!)
                    .font(.callout)
            }
        }
    }
}
#endif
```

Both versions of the struct compile because only one is exposed at a time.

- [ ] **Step 4: Build both schemes.**

```sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -3
```

Expected: both succeed.

- [ ] **Step 5: Confirm Sparkle is gone from the MAS bundle.**

```sh
DERIVED=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "Anglesite-*" -type d | head -1)
ls "$DERIVED/Build/Products/Debug/Anglesite.app/Contents/Frameworks/" 2>&1
```

The DevID Anglesite.app should show `Sparkle.framework`. To check the MAS build, build it explicitly and inspect:

```sh
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug -derivedDataPath /tmp/mas-derived build 2>&1 | tail -3
ls /tmp/mas-derived/Build/Products/Debug/Anglesite.app/Contents/Frameworks/ 2>&1
```

Expected for MAS: the directory either doesn't exist or contains no `Sparkle.framework`.

- [ ] **Step 6: Run tests.**

```sh
swift test --package-path . 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 7: Commit.**

```sh
git add Sources/AnglesiteApp/Updater.swift Sources/AnglesiteApp/SettingsView.swift Sources/AnglesiteApp/AnglesiteApp.swift
git commit -m "$(cat <<'EOF'
feat(mas): omit Sparkle + gh Settings panel from MAS build

Updater.swift (Sparkle 2.x wrapper) is entirely wrapped in
#if !ANGLESITE_MAS — the framework is not linked into the MAS app at
all. The "Check for Updates…" menu item is removed in MAS (App Store
handles updates).

SettingsView's GitHubAuthSection has two variants: the existing
gh-backed status panel in DevID, and a simpler one-liner with a
docs link in MAS. The DevID's `gh auth status` Process() call (now
through ProcessSupervisor from Task 8) is unreachable in MAS because
the view that triggers it is the DevID-only version.

Phase 10.1 Task 10 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: MAS smoke fixture

**Goal:** `scripts/create-smoke-fixture.sh --mas` builds the MAS scheme, sets up a bookmark for the fixture site, launches the app, walks the preview + edit + (npm run build, but not deploy) loop, and confirms helper stdout flowed through.

**Files:**
- Modify: `scripts/create-smoke-fixture.sh`

- [ ] **Step 1: Read the existing smoke fixture top-to-bottom.**

`scripts/create-smoke-fixture.sh` already drives a full DevID smoke. The MAS variant reuses ~80% of it. Read it end-to-end before editing.

- [ ] **Step 2: Add `--mas` flag parsing.**

At the top of the script, add:

```sh
#!/usr/bin/env bash
set -euo pipefail

MAS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mas) MAS=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SCHEME="Anglesite"
APP_NAME="Anglesite.app"
if [[ $MAS -eq 1 ]]; then
  SCHEME="AnglesiteMAS"
fi
```

(If the existing script doesn't parse args at all, this is a wholesale top-of-file replacement. If it already takes arguments, integrate `--mas` consistent with its existing pattern.)

- [ ] **Step 3: Build the right scheme.**

Wherever the existing script does `xcodebuild ... -scheme Anglesite ...`, change to `-scheme "$SCHEME"`.

- [ ] **Step 4: Add bookmark setup for MAS.**

Before launching the app, in the `if [[ $MAS -eq 1 ]]; then` branch, create a bookmark for the fixture site and inject it into the sandboxed app's container. The cleanest way: a small Swift helper invoked from the shell script.

Add `scripts/mas-set-bookmark.swift`:

```swift
#!/usr/bin/env swift
// Usage: mas-set-bookmark.swift <site-path> <container-sites-json-path>
//
// Creates a security-scoped bookmark for <site-path> and writes a minimal
// sites.json into the MAS app's container at the given path, including the
// bookmark Data as base64.

import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write("usage: mas-set-bookmark.swift <site-path> <sites-json-path>\n".data(using: .utf8)!)
    exit(2)
}

let sitePath = URL(fileURLWithPath: CommandLine.arguments[1])
let jsonPath = URL(fileURLWithPath: CommandLine.arguments[2])

let bookmark: Data
do {
    bookmark = try sitePath.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
} catch {
    FileHandle.standardError.write("bookmark create failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let id = sitePath.path  // any stable id; SiteStore re-derives anyway
let name = sitePath.lastPathComponent
let now = ISO8601DateFormatter().string(from: Date())

let sitesJSON: [[String: Any]] = [[
    "id": id,
    "name": name,
    "path": sitePath.absoluteString,
    "isValid": true,
    "missingSentinels": [],
    "lastSeen": now,
    "bookmarkData": bookmark.base64EncodedString()
]]

try FileManager.default.createDirectory(at: jsonPath.deletingLastPathComponent(), withIntermediateDirectories: true)
let data = try JSONSerialization.data(withJSONObject: sitesJSON, options: .prettyPrinted)
try data.write(to: jsonPath)
print("wrote \(jsonPath.path)")
```

Make executable: `chmod +x scripts/mas-set-bookmark.swift`.

Then in `create-smoke-fixture.sh` under the MAS branch:

```sh
if [[ $MAS -eq 1 ]]; then
  SITES_JSON="$HOME/Library/Containers/dev.anglesite.app.mas/Data/Library/Application Support/Anglesite/sites.json"
  echo "Setting up MAS bookmark for $FIXTURE_DIR"
  scripts/mas-set-bookmark.swift "$FIXTURE_DIR" "$SITES_JSON"
fi
```

**Important:** the `bookmarkData` field on `Site` is `Data?` and `Codable` synthesis encodes `Data` as base64 string by default in JSON. Verify by writing a quick swift one-liner if uncertain. If the synthesis encodes raw bytes differently in the target's `JSONEncoder`, adapt the helper script to match.

- [ ] **Step 5: Tee helper stdout for crash forensics.**

After launching the MAS app, wait briefly then capture the helper's stderr:

```sh
if [[ $MAS -eq 1 ]]; then
  HELPER_LOG="$HOME/Library/Containers/dev.anglesite.app.mas/Data/Library/Logs/AnglesiteHelper.log"
  echo "Helper log will accumulate at: $HELPER_LOG"
  # The helper writes via NSLog by default; users can `log stream --predicate 'subsystem == "dev.anglesite.app.mas.helper"'`
  # for live observation. The teed file fills as the smoke runs.
fi
```

(The helper itself can write to that path if `Sources/AnglesiteHelper/HelperService.swift` opens a log file early in `main.swift`. Simpler: rely on Console.app / `log stream` and skip the file tee — the smoke fixture's primary signal is "app + helper survived the run without crashing.")

- [ ] **Step 6: Run both fixtures.**

```sh
scripts/create-smoke-fixture.sh 2>&1 | tail -20         # DevID, must still pass
scripts/create-smoke-fixture.sh --mas 2>&1 | tail -40   # MAS
```

Expected: both pass. The MAS fixture should show: app launches, NSOpenPanel is bypassed (bookmark already set), site window opens, preview shows the fixture's index page rendered by the helper-spawned Astro dev server, no spawn errors in Console.

If the MAS fixture fails on a specific step (NSOpenPanel still prompts? Helper can't resolve bookmark? Astro listener not reachable?) — capture the exact failure mode in `docs/specs/2026-05-27-sandboxed-app-store-spike-notes.md` and consult the user. This is the highest-signal task in the milestone.

- [ ] **Step 7: Commit.**

```sh
git add scripts/create-smoke-fixture.sh scripts/mas-set-bookmark.swift
git commit -m "$(cat <<'EOF'
test(mas): smoke fixture variant — scripts/create-smoke-fixture.sh --mas

Builds the AnglesiteMAS scheme, pre-populates a security-scoped
bookmark in the sandbox container's sites.json, launches the app,
and walks the full preview + edit loop through the XPC helper.

Bookmark creation uses scripts/mas-set-bookmark.swift — a small Swift
shebang script that calls URL.bookmarkData(options: .withSecurityScope)
and writes the resulting bytes (base64-encoded) into the container's
sites.json. The MAS app picks the bookmark up at launch and never
prompts for the folder.

DevID smoke fixture is unaffected (no `--mas` flag → identical run).

Phase 10.1 Task 11 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Release pipeline + docs

**Files:**
- Modify: `scripts/release.sh`
- Create: `scripts/exportOptions-mas.plist`
- Modify: `docs/release.md`

- [ ] **Step 1: Add `scripts/exportOptions-mas.plist`.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>TEAM_ID_PLACEHOLDER</string>
    <key>uploadSymbols</key>
    <true/>
    <key>provisioningProfiles</key>
    <dict>
        <key>dev.anglesite.app.mas</key>
        <string>Anglesite MAS</string>
        <key>dev.anglesite.app.mas.helper</key>
        <string>Anglesite MAS Helper</string>
    </dict>
</dict>
</plist>
```

The `TEAM_ID_PLACEHOLDER` and provisioning-profile names are stamped at release time — the script substitutes them. (Or: the user creates the profiles in App Store Connect with those exact names and replaces the placeholder once.)

- [ ] **Step 2: Add `--mas` to `scripts/release.sh`.**

Find the existing argument parsing (or top of the script) and extend:

```sh
#!/usr/bin/env bash
set -euo pipefail

MAS=0
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mas) MAS=1; shift ;;
    *) VERSION="$1"; shift ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "usage: $0 [--mas] <version>" >&2
  exit 2
fi
```

Then branch on `$MAS` for the actual release logic. The DevID branch keeps the existing `xcodebuild archive` + `notarize` + `dmg` flow unchanged. The MAS branch:

```sh
if [[ $MAS -eq 1 ]]; then
  ARCHIVE="out/AnglesiteMAS-$VERSION.xcarchive"
  EXPORT_DIR="out/mas-$VERSION"

  xcodebuild archive \
    -project Anglesite.xcodeproj \
    -scheme AnglesiteMAS \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    | tail -20

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist scripts/exportOptions-mas.plist \
    -exportPath "$EXPORT_DIR" \
    | tail -20

  # productbuild signs + installer-wraps for App Store Connect.
  productbuild \
    --component "$EXPORT_DIR/Anglesite.app" /Applications \
    --sign "3rd Party Mac Developer Installer: David W. Keith" \
    "out/AnglesiteMAS-$VERSION.pkg"

  echo "Built out/AnglesiteMAS-$VERSION.pkg"
  echo "Upload with:"
  echo "  xcrun altool --upload-app -f out/AnglesiteMAS-$VERSION.pkg \\"
  echo "    --type macos -u \$APPLE_ID -p @keychain:AC_PASSWORD"
  exit 0
fi
```

(The script *prepares* the upload but doesn't run it — user-driven, since App Store Connect uploads need credentials and shouldn't auto-fire. If the existing script auto-runs notarization for DevID, mirror that pattern for MAS.)

- [ ] **Step 3: Add the MAS section to `docs/release.md`.**

Open `docs/release.md` and add a new section. Existing sections cover Sparkle key generation, appcast, notarization for the DevID build. The MAS section:

```markdown
## Mac App Store submission (AnglesiteMAS)

### One-time setup

1. Create an App Store Connect app record for `dev.anglesite.app.mas` (separate from the
   Developer ID app record). Set the bundle ID exactly.
2. Create two App Store provisioning profiles in [developer.apple.com](https://developer.apple.com):
   - "Anglesite MAS" for `dev.anglesite.app.mas`
   - "Anglesite MAS Helper" for `dev.anglesite.app.mas.helper`
3. In `scripts/exportOptions-mas.plist`, replace `TEAM_ID_PLACEHOLDER` with your team ID.

### Per-release checklist

Before running `scripts/release.sh --mas <version>`:

- [ ] Bump `MARKETING_VERSION` in `project.yml` for both `Anglesite` and `AnglesiteMAS`.
- [ ] Confirm both schemes build clean: `xcodebuild ... -scheme Anglesite build && xcodebuild ... -scheme AnglesiteMAS build`.
- [ ] Confirm both smoke fixtures pass: `scripts/create-smoke-fixture.sh && scripts/create-smoke-fixture.sh --mas`.
- [ ] Run the entitlements diff to confirm no `temporary-exception` keys snuck in:

  ```sh
  codesign -d --entitlements - out/mas-<version>/Anglesite.app
  codesign -d --entitlements - out/mas-<version>/Anglesite.app/Contents/XPCServices/AnglesiteHelper.xpc
  ```

  Neither output should contain `com.apple.security.temporary-exception.*` or
  `com.apple.security.cs.disable-library-validation`.

- [ ] Confirm Sparkle is absent from the MAS bundle:

  ```sh
  test ! -d out/mas-<version>/Anglesite.app/Contents/Frameworks/Sparkle.framework && echo OK
  ```

- [ ] Confirm `claude` CLI is not referenced in the MAS binary:

  ```sh
  ! strings out/mas-<version>/Anglesite.app/Contents/MacOS/Anglesite | grep -q 'claude' && echo OK
  ```

### Submission

```sh
scripts/release.sh --mas 0.1.0
# Then upload the resulting pkg:
xcrun altool --upload-app -f out/AnglesiteMAS-0.1.0.pkg \
  --type macos -u "$APPLE_ID" -p "@keychain:AC_PASSWORD"
```

After upload, in App Store Connect: fill out the version metadata, select the build, submit for review.
```

- [ ] **Step 4: Confirm scripts work (dry-run).**

The full archive + productbuild pipeline depends on a Mac Distribution cert + provisioning profiles, which may not be set up. Verify the script parses and reaches the cert-checking step:

```sh
scripts/release.sh --mas 0.1.0 2>&1 | head -20
```

Expected: either succeeds (if certs/profiles exist) or fails at the `xcodebuild archive` step with a "no profile matching" error. Either way, the script's structure is exercised.

- [ ] **Step 5: Commit.**

```sh
git add scripts/release.sh scripts/exportOptions-mas.plist docs/release.md
git commit -m "$(cat <<'EOF'
feat(mas): release.sh --mas pipeline + docs/release.md MAS section

`scripts/release.sh --mas <version>` archives the AnglesiteMAS scheme,
exports for App Store Connect using scripts/exportOptions-mas.plist,
and wraps with productbuild for upload via altool. The DevID branch
of the script is unchanged.

docs/release.md gains a "Mac App Store submission" section: one-time
ASC setup (app record + profiles), per-release checklist (version bumps,
smoke fixtures, entitlements diff, Sparkle/claude absence checks), and
upload instructions.

Phase 10.1 Task 12 of docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Final integration check + build-plan update

**Goal:** Confirm everything is wired correctly end-to-end. Update `docs/build-plan.md` and `CLAUDE.md` to mark Phase 10.1 as shipped.

**Files:**
- Modify: `docs/build-plan.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run every check.**

```sh
swift test --package-path . 2>&1 | tail -5                                            # all tests
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3       # DevID
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -3    # MAS
xcodebuild -project Anglesite.xcodeproj -target AnglesiteHelper -configuration Debug build 2>&1 | tail -3 # helper
scripts/create-smoke-fixture.sh 2>&1 | tail -10                                       # DevID smoke
scripts/create-smoke-fixture.sh --mas 2>&1 | tail -10                                 # MAS smoke
```

Expected: every line ending with success (`** BUILD SUCCEEDED **`, tests passing, smoke passing).

If any check fails, fix before committing the docs update.

- [ ] **Step 2: Update `docs/build-plan.md` to mark Phase 10 in progress with §1 complete.**

Find the `## Phase 10 — v2 polish` section. Currently it's a one-line summary. Replace with:

```markdown
## Phase 10 — v2 polish

Per design doc §12: Mac App Store build (sandboxed), Quick Look, Spotlight, Settings polish.

1. ✅ Sandboxed Mac App Store build. `AnglesiteMAS` ships alongside the existing `Anglesite` Developer ID target — same Swift sources, divergent entitlements + Info.plist + signing. Subprocess spawning routes through a new `SupervisorBackend` protocol (DevID uses `InProcessBackend` / direct `Process()`; MAS uses `XPCBackend` → `AnglesiteHelper.xpc` bundled in `Contents/XPCServices/`). Security-scoped bookmarks per site, threaded through `SiteStore.Site.bookmarkData` and every `SpawnSpec` headed to the helper. Chat panel, Sparkle, and the `gh`-backed GitHub Settings section are compiled out via `#if !ANGLESITE_MAS`. Design: [`docs/specs/2026-05-27-sandboxed-app-store-design.md`](specs/2026-05-27-sandboxed-app-store-design.md). Plan: [`docs/specs/2026-05-27-sandboxed-app-store-plan.md`](specs/2026-05-27-sandboxed-app-store-plan.md). Remaining v2 work: native Anthropic API chat client (10.2), Quick Look extension (10.3), Spotlight metadata (10.4), Settings polish (10.5).
2. (10.2) Native Anthropic API chat client.
3. (10.3) Quick Look extension for site projects.
4. (10.4) Spotlight metadata indexer.
5. (10.5) Theme picker / model picker / plugin-path override in Settings.
```

- [ ] **Step 3: Update `CLAUDE.md`'s "Current phase" line.**

Find the line that currently reads "Current phase: **Phase 10** — v2 polish (sandboxed App Store build, Quick Look, Spotlight, Settings polish). Phases 0–9 are complete: …" and replace the Phase 10 portion:

```markdown
See [`docs/build-plan.md`](docs/build-plan.md) for the phased roadmap. Current phase: **Phase 10.2** — native Anthropic API chat client (chat in MAS). Phase 10.1 (sandboxed Mac App Store build with helper-tool architecture) shipped. Phases 0–9 are complete: multi-window (#54), health badge (#31), image-drop → `optimize-images` (#32), per-edit undo (#33). Outstanding asterisks from earlier phases: opt-in primed npm cache size budget (#6), Sparkle manual key/appcast setup (DevID only — MAS gets App Store updates), app icon assets (#55), symlink-path normalization in `SiteStore.identifier(for:)` (#56). Deferred Release-track: Developer ID re-sign of embedded Node + notarization (#1/#4).
```

- [ ] **Step 4: Commit.**

```sh
git add docs/build-plan.md CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: mark phase 10.1 complete (sandboxed MAS build shipped)

Updates the build plan with a full §10.1 paragraph + the remaining
Phase 10 sub-projects (10.2–10.5). CLAUDE.md "Current phase" flips
from "Phase 10" (the whole milestone) to "Phase 10.2" (the next
specific sub-project — native Anthropic API chat client).

Phase 10.1 Task 13 (final) of
docs/specs/2026-05-27-sandboxed-app-store-plan.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push 2>&1 | tail -2
```

---

## Decision points during execution

A few places where a subagent should stop and consult the user rather than improvise:

1. **Task 0 spike fails on any macOS version.** Stop. The libgit2/SwiftGit2 fallback is a much bigger scope change; user-driven decision.
2. **Task 3 reveals public-API breakage in `ProcessSupervisor`** (e.g., a caller depends on a private internal that's now in `InProcessBackend`). Pause, share the diff, ask: keep the private API stable by re-exposing through `ProcessSupervisor`, or migrate the caller? Usually re-expose.
3. **Task 5 or 11 reveals the helper can't `Process()` a binary that worked under DevID** (sandbox profile too restrictive, missing entitlement). Document the exact failure in the spike-notes file, propose the entitlement that would fix it, ask before adding — the spec's entitlement list is deliberately tight.
4. **Task 11 MAS smoke fails with NSOpenPanel still prompting** (bookmark didn't persist correctly). Could indicate `Codable` encoding the `Data` field differently than the script expects (raw bytes vs base64), or the container path being wrong. Verify by reading `sites.json` from the container path manually and decoding.
5. **Task 12 `productbuild` fails** because no Mac Distribution cert / provisioning profile exists. Expected on a fresh machine; document the prerequisite in `docs/release.md` (already done in Step 3) and call the task done — actual MAS submission is a separate event the user drives.

## Self-review notes

After writing this plan, the writer checked:

- **Spec coverage:** §Target structure → Task 1; §SupervisorBackend → Task 2-3; §XPC service → Task 4-5; §XPCBackend → Task 6; §Security-scoped bookmarks → Task 7; §Entitlements → Tasks 1, 5; §Feature flags → Tasks 9, 10; §Testing → Task 11 + tests inline in Tasks 2, 7; §Submission pipeline → Task 12; §Risks Critical (/usr/bin/git) → Task 0. §Non-goals are documented in the spec and explicitly not covered.
- **Type consistency:** `SpawnSpec`, `SpawnedProcessHandle`, `ProcessResult`, `SupervisorBackendError`, `SecurityScopedBookmark.Resolved`, `SecurityScopedBookmark.BookmarkError`, `kAnglesiteHelperServiceName`, `AnglesiteHelperProtocol`, `HelperClientProtocol`, `HelperService`, `ChildProcess`, `HelperClientHandler`, `XPCBackend`, `InProcessBackend`, `ProcessSupervisor.Handle`, `ProcessSupervisor.StdinHandle` — all defined in their introducing task and referenced consistently downstream.
- **Placeholders:** `TEAM_ID_PLACEHOLDER` in `exportOptions-mas.plist` is the only intentional placeholder (the user must fill it once when setting up App Store Connect; documented in `docs/release.md`). No "TODO" or "implement later" anywhere in the implementation steps.
