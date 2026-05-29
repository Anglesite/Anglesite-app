# Phase 10.1 — Task 6.6 Sub-Spike Notes (fd-passing vs inherit-baseline for helper writes)

**Date:** 2026-05-28
**Gates:** Task 7 (folder-access mechanism in `SiteStore` / `XPCBackend`)
**Predecessors:**
- `docs/specs/2026-05-27-sandboxed-app-store-spike-notes.md` (Task 0 — helper-child *reads* the top of a user-selected folder)
- `docs/specs/2026-05-28-bookmark-signed-subspike-notes.md` (Task 6.5 — helper CANNOT resolve a `.withSecurityScope` bookmark, even real-signed; bookmark must be resolved in the APP)
- `docs/specs/2026-05-28-inherit-write-subspike-notes.md` (Task 6.6 inherit half — `com.apple.security.inherit` does NOT carry the app's held grant to the helper)
- `docs/specs/2026-05-28-node-sandbox-subspike-notes.md` (vendored Node runs inside the sandboxed helper)

**Outcome:** DONE_WITH_CONCERNS. **VERDICT: fd-passing does NOT extend write (or file-content read) access to the sandboxed helper — and the plain-inherit baseline fails too.** This is the "everything fails" branch. **Task 7 cannot use either fd-passing or plain-inherit; it must use sandbox-extension tokens (libsandbox SPI) or a re-architecture (do the privileged FS work in the app, not the helper).** FLAGGED LOUDLY below.

## The question

The corrected Task 7 design (from 6.5/6.6) has the **app** hold the security-scoped grant (proven to work in-app) and the **helper** get folder access via some passing mechanism. This spike prototypes **fd-passing** — the app opens a directory file descriptor *while the scope is held* and passes the `NSFileHandle` to the helper over XPC — and compares it against the **plain-inherit baseline** (helper/child reach the path by absolute path with no fd). The decisive question for Anglesite: **can a process the helper SPAWNS (Node, which does absolute-path filesystem I/O — `dist/`, `node_modules/`, `.wrangler/`, `public/images/`) write throughout the granted folder's subtree?**

## Environment + signing proof (REAL Apple Development, not ad-hoc)

```
$ sw_vers
ProductName:    macOS
ProductVersion: 26.5
BuildVersion:   25F71              # Tahoe

$ xcodebuild -version
Xcode 26.5  (Build 17F42)

$ security find-identity -v -p codesigning
  1) 3103065CBD813596CE80E32B65CB13DFA250FE12 "Apple Development: dwk@mac.com (KH7H8Y25RT)"
     1 valid identities found
```

Signing: `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY="Apple Development: dwk@mac.com (KH7H8Y25RT)"`, `DEVELOPMENT_TEAM=UX3L9R8RSL`, hardened runtime ON, no provisioning profile (development-signed local run).

### `codesign -dv --verbose=4` proof — really Apple-Development-signed, NOT ad-hoc

```
===== APP =====
Identifier=io.dwk.fdspike.app
CodeDirectory v=20500 size=446 flags=0x10000(runtime) hashes=3+7 location=embedded
Authority=Apple Development: dwk@mac.com (KH7H8Y25RT)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=UX3L9R8RSL

===== HELPER (Contents/XPCServices/ProbeHelper.xpc) =====
Identifier=io.dwk.fdspike.probe
CodeDirectory v=20500 size=640 flags=0x10000(runtime) hashes=9+7 location=embedded
Authority=Apple Development: dwk@mac.com (KH7H8Y25RT)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=UX3L9R8RSL

# `codesign -dvvv` contains NO "adhoc" string for either binary.
```

Both app and embedded XPC helper carry the full Apple-Development chain + `TeamIdentifier=UX3L9R8RSL` + hardened-runtime flag (0x10000). Genuinely Apple-Development-signed.

Entitlements (codesign-verified post-build):
- **App:** `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope` (+ Xcode-Debug `get-task-allow`).
- **Helper:** `app-sandbox`, `inherit`, `files.user-selected.read-write` (+ `get-task-allow`).

## What was built

Throwaway SwiftUI/AppKit app + embedded XPC service at `/tmp/FDSpike/` (**not committed**). xcodegen → xcodebuild, real-signed as above, copied to `~/Desktop/FDSpike.app` and run from there (signed sandboxed apps refuse to launch from `/private/tmp` — Task 6.5 gotcha).

Helper protocol:
```swift
@objc protocol FDProbe {
    func runTests(dirFD: FileHandle, absPath: String, reply: @escaping (String) -> Void)
}
```

App flow: `NSOpenPanel` → select a fresh, isolated `~/Desktop/fdspike-target` (pre-created empty + `existing.txt` marker) → `startAccessingSecurityScopedResource()` (held for the whole test) → `open(path, O_RDONLY|O_DIRECTORY)` UNDER the live scope → wrap as `NSFileHandle(fileDescriptor:closeOnDealloc:false)` → pass over `NSXPCConnection` (the remote `NSXPCInterface` allows `NSFileHandle`; the kernel duplicates the fd into the helper) together with the plain absolute path string. The app confirmed it holds a live grant before the call (`startAccessing… == true`, app-side write OK).

The `NSFileHandle` fd argument transfers correctly: the helper received a valid fd (`fstat` ok, points at the granted dir, inode matches — see D0).

### Gotchas recorded (for Task 7 / future spikes)
- **The sandboxed app cannot pre-create the target dir in the real `~/Desktop`** (no grant yet) — `FileManager.createDirectory` fails silently and the panel falls back to showing Desktop. Fix: the test harness pre-creates the target *outside* the sandbox before launch, and the app points `panel.directoryURL` at it.
- **Real home:** inside the sandbox `NSHomeDirectory()` is the container; resolve the true home via `getpwuid(getuid())->pw_dir`.
- **XPC service would not launch** (`NSCocoaErrorDomain 4099 … "No such process" / lookup error 3`) until the helper's `Info.plist` carried an explicit `XPCService` dict (`ServiceType = Application`). xcodegen's auto-generated plist (`GENERATE_INFOPLIST_FILE=YES`) omits it for the `xpc-service` product type on this toolchain. Carry an explicit helper Info.plist in Task 7's MAS target.
- **Powerbox panel automation:** in-app `CGEvent` Return posting triggers the Accessibility-permission prompt and is unreliable; driving from another process via System Events targeting the FDSpike *process* leaks keystrokes (the powerbox panel is hosted by `com.apple.appkit.xpc.openAndSavePanelService`, not the app). What worked: launch via `open` (proper LaunchServices activation → app/panel becomes key), point `panel.directoryURL` at the pre-created target so the default **Grant** button grants *that* dir, then send a single global `key code 36` (Return) via System Events.

## Test matrix — verbatim helper output (the conclusive run)

App pre-amble (confirms the app holds a live grant and a valid dir fd was opened under scope):
```
[app] selected: /Users/dwk/Desktop/fdspike-target
[app] startAccessingSecurityScopedResource() in-app: true
[app] app-side write OK (grant is live)
[app] opened dir fd=3 on /Users/dwk/Desktop/fdspike-target
[app] calling helper runTests…
```

Helper received the fd correctly:
```
[helper] received dirFD=3 absPath=/Users/dwk/Desktop/fdspike-target
[helper] helper pid=59953 euid=501
```

### D0 — received-fd diagnostics (isolates fd transfer vs access-rights propagation)
```
[D0] fstat ok: mode=40755 ino=45222228 isDir=true
[D0] readdir THROUGH fd: ["app-grant-probe.txt", "existing.txt"]  (read access via fd: YES)
[D0] openat-READ existing.txt THROUGH fd FAILED errno=1 (Operation not permitted)
```
**The fd transferred perfectly** (valid, points at the granted dir, inode matches). The helper CAN `readdir` the directory **through the fd handle itself** (an already-open dir fd inherently supports enumeration). But `openat(fd, "existing.txt", O_RDONLY)` to read a **file's contents** through the fd is **EPERM**. So the fd carries the *open-directory handle* but NOT the sandbox extension that the security-scoped grant represents.

| Test | What it proves | Result | Key verbatim output |
|---|---|---|---|
| **T1** — helper `mkdirat`/`openat` write via passed fd | does the fd carry WRITE to the subtree for the helper itself? | **FAIL** | `[T1] mkdirat(deep) FAILED errno=1 (Operation not permitted)` |
| **T2** — child via `fchdir(fd)` + relative write | does a SPAWNED CHILD inherit fd-granted access for relative writes? | **FAIL** | `mkdir: deep: Operation not permitted` (child also can't `getcwd`) |
| **T3** — child ABSOLUTE-path write (the real Node case) | does a spawned child get ABSOLUTE-path write (Node/Astro/npm/wrangler)? | **FAIL** | `mkdir: /Users/dwk/Desktop/fdspike-target/deep: Operation not permitted` |
| **B1** — helper absolute write, NO fd (inherit baseline) | does `inherit` alone give the helper absolute-path write? | **FAIL** | `NSCocoaErrorDomain 513 … You don't have permission … NSPOSIXErrorDomain Code=1` |
| **B2** — child absolute write, NO fd (inherit baseline) | does `inherit` alone give a spawned CHILD absolute-path write? | **FAIL** | `mkdir: /Users/dwk/Desktop/fdspike-target/deep: Operation not permitted` |

Post-run, the app (grant still held) confirmed nothing landed: `deep/sub not present`.

### Unified-log sandbox capture
`log show --last 3m` filtered for `ProbeHelper` / `sh` / `mkdir` / `fdspike` / `sandbox` / `deny` surfaced **no kernel `Sandbox: … deny` lines** — consistent with Task 0 / 6.5 / 6.6. The denials manifest as userspace `EPERM` / Cocoa "you don't have permission", and `log show` persistence for short-lived sandboxed children is unreliable on this OS. The XPC replies above (`EPERM` on `mkdirat`, `openat` content-read, and child `mkdir`) are the authoritative, unambiguous evidence.

## VERDICT

**This is the "everything fails" branch** of the four interpretations laid out for the spike — with a sharper diagnosis thanks to D0:

- **T3 (fd → child absolute write): FAIL.** fd-passing does NOT extend to spawned children's absolute writes.
- **B2 (inherit → child absolute write): FAIL.** Plain `inherit` does not cover child absolute writes either (re-confirms the Task 6.6 inherit finding end-to-end).
- **T1 / B1 (helper-direct write): also FAIL.** Not even the helper *itself* can write — neither via the passed fd nor by absolute path.
- **D0 nuance:** the passed fd carries *directory enumeration* (readdir of the open handle) but **not file-content read and not any write.** A file descriptor opened under a security-scoped grant does **not** transport that grant's sandbox extension across an XPC boundary into a different sandbox. The receiving process is still gated by its own sandbox profile, which has no extension for the path.

### Why (interpretation)

A security-scoped grant is a **sandbox extension** bound to the *granted* process's sandbox. `startAccessingSecurityScopedResource()` issues/consumes that extension in the **app**. Passing an open fd over XPC duplicates the *file-descriptor object* (so `fstat`/`readdir`-the-handle work — those are intrinsic to holding an open dir fd), but it does **not** transfer the sandbox extension. The helper's kernel sandbox check on `openat`-for-content, `mkdirat`, and any path-based open consults the *helper's* extension set, which is empty for this path. Same root cause as Task 6.6's inherit failure (the grant is process-bound and does not cross the XPC hop) — this spike additionally proves that wrapping it in an fd does not smuggle it across.

This is fully consistent with, not contradictory to, Task 0: the read access helper-children enjoyed there came from the helper's own sandbox state in that flow, not from the app's grant crossing XPC.

### FLAG (LOUD): MAS write-path is NOT solved by fd-passing or inherit

Neither of the "good outcome" branches (fd-passing, plain-inherit) is available. The remaining options for Task 7:

## Task 7 mechanism recommendation

**Recommended: sandbox-extension tokens (the Apple-sanctioned cross-process grant mechanism)** — with a re-architecture fallback if the SPI proves App-Store-risky.

1. **Sandbox-extension tokens (libsandbox SPI).** The app holds the scope and **issues** a file extension token for the path scoped to the helper, then sends the *token string* over XPC; the helper **consumes** it to add the extension to its own sandbox, after which absolute-path I/O (and its spawned children's I/O, via the helper→child `inherit` relationship that DOES work) succeeds throughout the subtree.
   - APIs: `sandbox_extension_issue_file_to_process` / `sandbox_extension_issue_file` (issue, app side) and `sandbox_extension_consume` (consume, helper side), from `<sandbox.h>` / libsandbox. These are **SPI, not public API** — usable under a Development cert but **App-Store-review-risky**; confirm acceptability before committing (or gate behind the non-MAS build and keep MAS on the re-architecture below).
   - **Must be verified in a follow-up spike** (this spike did not test tokens): that an issued+consumed token grants the helper *and a `Process()` child it spawns* write throughout the subtree (`deep/sub/...`), under real signing — exactly the T1/T3 matrix, but with a token consumed first.

2. **Re-architecture fallback (no SPI) — do the privileged FS work in the APP, not the helper.** The app already has the grant and writes fine in-process (proven: `app-side write OK`). Options:
   - Spawn Node/Astro/npm/wrangler **from the app itself** (the app holds the scope; `inherit` carries it to the app's *direct* children — this is the spawn relationship that works), and use the helper only for work that does NOT touch the user folder. This conflicts with the current "helper owns all `Process()`" topology (Tasks 5/6) and would need the supervisor to live app-side for MAS — a meaningful redesign, but uses **only public, App-Store-safe** mechanisms.
   - Or keep the helper but have it stream file *operations* back to the app to perform (the app is the only writer). Heavy for Node's high-volume, watcher-driven I/O — likely impractical for `astro dev` / `npm install`.

**Do NOT plan Task 7 around fd-passing or plain `inherit` for user-folder writes** — both are ruled out by observed, real-signed runs (6.6 inherit half + this fd half).

### MAS viability note
MAS is **not** dead, but the simple designs are. The app-resolves-scope half still works; the gap is purely "get the grant to the *helper* (and its Node children)." Tokens are the cleanest fix if review-acceptable; otherwise the writer has to be the app. Resolve this before locking Task 7, and ideally before committing to the helper-owns-all-spawns topology for the MAS target.

## What was NOT tested

- **Sandbox-extension tokens themselves** (`sandbox_extension_issue_file_to_process` / `sandbox_extension_consume`). This spike rules OUT fd-passing and inherit; it does not yet prove the token replacement. That is the load-bearing next spike before Task 7.
- **Distribution / Mac App Store provisioning-profile signing.** Development cert + `get-task-allow`, local run. The failure is rooted in sandbox-extension process-binding (which a Distribution profile cannot change), so reproduction under MAS signing is essentially certain — Task 12 should still confirm on a profiled build, and tokens specifically must be checked against actual App Store review.
- **Real Node binary for T3/B2.** Tests used `/bin/sh` (which, like Node, does absolute-path opens); the Node sub-spike already proved the vendored Node *launches* in the helper. The EPERM is at the kernel sandbox layer (path open), identical for `sh` and `node`, so substituting Node would not change the verdict.
- **`XPCService ServiceType` variants.** The helper ran with `ServiceType = Application` (own process, own entitlements). A different service-type arrangement was not compared; the fd/extension behavior is a kernel-sandbox property, not a service-type one.
- **Files OUTSIDE the granted tree, rename/unlink ops, very deep trees, long-lived grants** (the multi-minute `astro dev` case).
- **macOS 14 / 15.** This machine is macOS 26.5 only. The sandbox-extension process-binding semantics have been stable for years, so reproduction on 14/15 is very likely.

## Status

**DONE_WITH_CONCERNS.** Question answered with a real, observed, Apple-Development-signed end-to-end run, with a D0 diagnostic that pinpoints the failure: the fd transfers but the security-scoped sandbox extension does not ride along, so the helper gets directory-enumeration only — no file-content read, no writes — and its spawned children get nothing. fd-passing and plain-inherit are both ruled out for user-folder writes. Task 7 must use sandbox-extension tokens (follow-up spike required) or move the privileged FS work into the app. The throwaway spike project at `/tmp/FDSpike/` is not committed.
