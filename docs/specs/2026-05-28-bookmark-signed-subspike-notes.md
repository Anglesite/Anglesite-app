# Phase 10.1 — Task 6.5 Sub-Spike Notes (Signed-Build Security-Scoped Bookmarks across XPC)

**Date:** 2026-05-28
**Gates:** Task 7 (security-scoped bookmarks in `SiteStore`)
**Predecessor:** `docs/specs/2026-05-27-sandboxed-app-store-spike-notes.md` (Task 0, Finding 2)
**Outcome:** DONE — question answered. **VERDICT: FAIL.** Real Apple Development signing does **not** make `.withSecurityScope` bookmark resolution work across an XPC boundary. Task 7 needs a redesign.

## The question

Does cross-process security-scoped bookmark resolution work under **real** Apple Development code signing? Specifically:

1. The app creates a `.withSecurityScope` bookmark from an `NSOpenPanel`-selected folder.
2. It sends the bookmark `Data` to its embedded sandboxed XPC helper over `NSXPCConnection`.
3. The helper calls `URL(resolvingBookmarkData:options:.withSecurityScope, …)` + `startAccessingSecurityScopedResource()` and reads the folder.

## The ad-hoc baseline being compared against

Task 0 (ad-hoc signed, `CODE_SIGN_IDENTITY = -`, no Team ID) found this **fails** with `NSCocoaErrorDomain 259` ("The file couldn't be opened because it isn't in the correct format."). The Task 0 hypothesis was that the failure was an artifact of ad-hoc signing — that a real cert carrying a stable **Team ID** would let `scopedbookmarksagent` validate the bookmark creator's identity and the resolution would succeed. **This sub-spike disproves that hypothesis.** The failure is identical under real signing.

## Environment

```
$ sw_vers
ProductVersion:  26.5   (Tahoe)
BuildVersion:    25F71

$ xcodebuild -version
Xcode 26.5  (Build 17F42)

$ security find-identity -v -p codesigning
  1) 3103065CBD813596CE80E32B65CB13DFA250FE12 "Apple Development: dwk@mac.com (KH7H8Y25RT)"
     1 valid identities found

$ openssl x509 -noout -subject -issuer  (the leaf)
subject= UID=KYBV4S3T74, CN=Apple Development: dwk@mac.com (KH7H8Y25RT), OU=UX3L9R8RSL, O=David Keith, C=US
issuer = CN=Apple Worldwide Developer Relations Certification Authority, OU=G3, O=Apple Inc., C=US
```

Signing identity used: **`Apple Development: dwk@mac.com (KH7H8Y25RT)`**, `DEVELOPMENT_TEAM=UX3L9R8RSL` (the cert's OU), `CODE_SIGN_STYLE=Manual`, hardened runtime on, no provisioning profile. A development-signed app with `get-task-allow` launches locally with no App Store / Distribution profile, as expected.

### `codesign -dv` proof — really Apple-Development-signed, NOT ad-hoc

```
===== APP =====
Identifier=io.dwk.bookmarkspike.app
CodeDirectory v=20500 size=452 flags=0x10000(runtime) ...
Authority=Apple Development: dwk@mac.com (KH7H8Y25RT)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=UX3L9R8RSL

===== HELPER (Contents/XPCServices/ProbeHelper.xpc) =====
Identifier=io.dwk.bookmarkspike.probe
CodeDirectory v=20500 size=518 flags=0x10000(runtime) ...
Authority=Apple Development: dwk@mac.com (KH7H8Y25RT)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=UX3L9R8RSL

# `codesign -dvvv` contains no "adhoc" string for either binary.
```

Both the app and the embedded XPC helper carry the full Apple-Development chain and `TeamIdentifier=UX3L9R8RSL`. This is a genuinely Apple-Development-signed build, not ad-hoc.

Entitlements (post-build, codesign-verified):

- **App:** `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, plus `get-task-allow` (injected by Xcode for Debug).
- **Helper:** `app-sandbox`, `inherit`, `files.user-selected.read-write`, plus `get-task-allow`.

## The WWDR G3 intermediate gotcha (matters for Task 12 — release pipeline)

When the Apple Development cert was first imported, `security find-identity -v -p codesigning` reported **0 valid identities** even though the cert and its private key were present in the keychain. The leaf is issued by **"Apple Worldwide Developer Relations Certification Authority", OU=G3** (see the `issuer=` line above). macOS could not build a trust chain to the Apple Root because the **WWDR CA G3 intermediate** was missing/expired in the keychain. The identity only became valid after the **WWDR G3 intermediate was installed**. Until then, every `codesign` and Xcode signing attempt would have failed with an opaque "no identity found" error.

**Release-pipeline implication:** the Task 12 CI/release machine (and any new dev box) must have the current Apple WWDR intermediate installed, or signing silently has zero usable identities. Bake an explicit "import WWDR G3 (and G4+ as Apple rotates them) into the keychain" step into the release setup, and assert `security find-identity -v -p codesigning` returns ≥1 identity before attempting to sign. Do not assume a freshly-imported leaf is enough.

## What was built

Throwaway project at `/tmp/BookmarkSpike/` (**not committed**, will be deleted), mirroring the Task 0 structure but real-signed:

- `BookmarkSpike.app` — minimal AppKit app. On launch it opens an `NSOpenPanel` pre-pointed at `…/Anglesite-app`, creates a `.withSecurityScope` bookmark from the panel-returned URL, and calls the helper over `NSXPCConnection`.
- `ProbeHelper.xpc` — embedded XPC service exposing one method:
  ```swift
  @objc protocol Probe {
      func resolveAndRead(scopedBookmark: Data, reply: @escaping (String, Int32) -> Void)
  }
  ```
  Implementation: `URL(resolvingBookmarkData:options:.withSecurityScope, relativeTo:nil, bookmarkDataIsStale:&stale)` → `startAccessingSecurityScopedResource()` → `FileManager.contentsOfDirectory(atPath:)` → `reply(log, status)` with `0 = success`, `-1 = resolve threw`. `defer { stopAccessingSecurityScopedResource() }`.
- Built with xcodegen → xcodebuild, manual signing as above. App run from `~/Desktop/BookmarkSpike.app` (launching a sandboxed signed app from `/private/tmp` was silently refused by LaunchServices — a separate, minor gotcha; copying the bundle to `~/Desktop` fixed it).

Test methodology: the app drives its own `NSOpenPanel` programmatically (the panel pre-points at the target dir; the app posts a synthetic Return to the sheet to commit the powerbox grant — the same default-button codepath a user click takes), so no external GUI automation / Accessibility grant is needed.

## Verbatim output (the conclusive run)

```
[app] launched. pid=53895
[app] auto-accepting panel (url=/Users/dwk/Developer/github.com/Anglesite/Anglesite-app)
[app] selected: /Users/dwk/Developer/github.com/Anglesite/Anglesite-app
[app] scoped bookmark: 804 bytes
[app] startAccessing in-app: true
[app] calling helper...
[app] helper status=-1
[helper] received scoped bookmark: 804 bytes
[helper] RESOLVE FAILED: NSCocoaErrorDomain 259: The file couldn’t be opened because it isn’t in the correct format.
[app] === VERDICT: FAIL ===
[app] XPC connection invalidated
```

Key observations:

- `[app] startAccessing in-app: true` — the exact same 804-byte scoped bookmark resolves and grants scope **in the creating app**. The bookmark data is valid; it is not corrupt.
- `[helper] RESOLVE FAILED: NSCocoaErrorDomain 259` — the **identical** error code/message the Task 0 ad-hoc spike produced. Real signing changed nothing on the helper side.
- The 804-byte payload matches Task 0's scoped-bookmark size exactly, confirming the same bookmark format is being exercised.

## Why it fails (interpretation)

A `.withSecurityScope` bookmark created by a sandboxed app is an **app-scoped** bookmark — its scope is bound to the *creating* sandbox identity (the app's container + code identity), not merely to the Team ID. The XPC helper runs in a **separate sandbox container with a different code identity** (`io.dwk.bookmarkspike.probe` vs `io.dwk.bookmarkspike.app`), even though both share the bundle and Team ID `UX3L9R8RSL`. `scopedbookmarksagent` refuses to hand the scope to a process that is not the creator, and `URL(resolvingBookmarkData:options:.withSecurityScope)` surfaces that refusal as `NSCocoaErrorDomain 259`. A real Team ID does not relax this: the binding is per-process-identity, not per-team. (This also tracks with the `DetachedSignatures` sqlite errors Task 0 saw from `scopedbookmarksagent`.)

## VERDICT

**FAIL.** `.withSecurityScope` bookmark resolution does **not** work across the XPC boundary under real Apple Development signing. The hypothesis from Task 0 Finding 2 — that a stable Team ID would fix it — is disproven. The behavior is identical to ad-hoc.

## Implications for Task 7 (redesign required)

Task 7 as originally designed — *"the app creates a scoped bookmark, persists it on `SiteStore.Site.bookmarkData`, and the helper later resolves it with `.withSecurityScope`"* — **cannot work**. Pick one of the following redesigns. **Recommendation: Option A.**

### Option A (recommended) — resolve scope in the app, pass an open file handle / fd to the helper

- The **app** owns the scoped bookmark, resolves it (`.withSecurityScope`), and calls `startAccessingSecurityScopedResource()`. This works (proven: `startAccessing in-app: true`).
- For each operation, the app opens the resource (an `NSFileHandle` / open `O_DIRECTORY` fd for the site root, or per-file handles) and **passes the open file descriptor to the helper over XPC**. File descriptors transfer across XPC and carry their access rights with them; the helper operates on the fd without needing its own scope grant.
- For git-style work (Task 8 already moved to libgit2 in the XPCBackend), pass the resolved **directory fd**; libgit2 can operate relative to an open dir fd (`git_repository_open` against a path the app keeps in scope, or `*at()`-style operations). If libgit2 cannot take an fd directly, keep the app's scope open for the duration of the helper call (the app holds `startAccessing…`/`stop…` around the XPC round-trip) and pass the **plain path**; the helper reaches it via `com.apple.security.inherit` while the app holds the live grant.
- Persistence across launches: the **app** re-resolves its app-scoped bookmark on each launch (works in-app), then re-vends fds/paths to the helper. Cross-launch access is fine because the *app* is the bookmark owner.

### Option B (fallback) — `inherit` + plain (non-scoped) bookmark for path recovery only

- Store a **plain** (non-`.withSecurityScope`) bookmark on `SiteStore.Site.bookmarkData` purely to recover the *path* across launches. Task 0 confirmed plain bookmarks transfer and resolve in the helper.
- The helper reaches the folder via `com.apple.security.inherit` while the app holds a live user-selected grant. **Caveat:** this likely requires the user to re-grant access (re-pick the folder) after a relaunch, because `inherit` only conveys access the app currently holds — it is not a persistent grant. The "open last site automatically without re-prompting" UX would be degraded. Accept this only if Option A proves impractical.

Do **not** plan on the helper resolving a `.withSecurityScope` bookmark itself under any signing tier (Development or Distribution) — that is the thing this spike just ruled out.

## What was NOT tested

- **Distribution / Mac App Store provisioning-profile signing.** This spike used a Development cert + `get-task-allow` for a local run. A Distribution-profiled build *might* behave differently, but the failure is rooted in cross-process scope ownership (not the cert tier), so a Distribution profile is very unlikely to change the result. Task 12 should still confirm on a profiled build.
- **Write operations.** Only a directory read (`contentsOfDirectory`) was exercised.
- **Files outside the selected directory tree** (e.g. deep subpaths of `~/Sites/<name>/`).
- **fd-passing over XPC** (Option A's mechanism) — not yet prototyped; recommend a quick follow-up spike to confirm `NSFileHandle`/fd transfer + libgit2-against-fd before committing Task 7's design.
- **macOS 14 / 15.** This machine is macOS 26.5 only. The bookmark-agent validation rules could differ on older OSes, but the cross-process app-scope binding has been the documented behavior for years, so reproduction on 14/15 is very likely.
- **Unified-log capture of `scopedbookmarksagent` / helper messages** — `log show` did not surface the helper's `os_log` lines in this session (os_log persistence quirk under the sandboxed helper); the helper's `NSError` reply over XPC is the authoritative evidence and is unambiguous.

## Status

**DONE.** Question answered with a real, observed, Apple-Development-signed end-to-end run. Verdict: FAIL. Task 7 must adopt Option A (app-resolves-scope, passes fd/path to helper). The throwaway spike project at `/tmp/BookmarkSpike/` is not committed.
