# Phase 10.1 — Task 6.6 Sub-Spike Notes (inherit + writes into subdirs across the app→helper boundary)

**Date:** 2026-05-28
**Gates:** Task 7 (security-scoped bookmarks in `SiteStore`)
**Predecessors:**
- `docs/specs/2026-05-27-sandboxed-app-store-spike-notes.md` (Task 0 — helper-child *reads* the top of a user-selected folder)
- `docs/specs/2026-05-28-bookmark-signed-subspike-notes.md` (Task 6.5 — helper CANNOT resolve a `.withSecurityScope` bookmark, even real-signed; bookmark must be resolved in the APP)
- `docs/specs/2026-05-28-node-sandbox-subspike-notes.md` (Node runs inside the sandboxed helper)

**Outcome:** DONE. **VERDICT: FAIL.** `com.apple.security.inherit` does **not** extend the app's held security-scoped grant to the XPC helper (or to children the helper spawns) for writes — or for reads — into the user-selected folder. The grant simply never reaches the helper. Task 7 must use **fd-passing**.

## The question

When a sandboxed APP holds a security-scoped grant on a user-selected folder (resolved a `.withSecurityScope` bookmark + `startAccessingSecurityScopedResource()`), does `com.apple.security.inherit` extend that grant to a child process spawned by the app's XPC HELPER — for WRITES and into SUBDIRECTORIES — using only a plain absolute path (NO bookmark resolution in the helper)?

This is the make-or-break question for the corrected bookmark design (Task 6.5 Option B). Anglesite's real workload has the helper spawn Node, which writes all over the site folder: Astro `dist/`, `npm install` → `node_modules/`, wrangler `.wrangler/`, image drops into `public/images/`.

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

### `codesign -dvvv` proof — really Apple-Development-signed, NOT ad-hoc

```
===== APP =====
Identifier=io.dwk.inheritwritespike.app
CodeDirectory v=20500 size=456 flags=0x10000(runtime) hashes=3+7 location=embedded
Authority=Apple Development: dwk@mac.com (KH7H8Y25RT)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=UX3L9R8RSL

===== HELPER (Contents/XPCServices/ProbeHelper.xpc) =====
Identifier=io.dwk.inheritwritespike.probe
CodeDirectory v=20500 size=554 flags=0x10000(runtime) hashes=6+7 location=embedded
Authority=Apple Development: dwk@mac.com (KH7H8Y25RT)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=UX3L9R8RSL

# `codesign -dvvv` contains no "adhoc" string for either binary.
```

Both app and embedded XPC helper carry the full Apple-Development chain + `TeamIdentifier=UX3L9R8RSL` + hardened-runtime flag (0x10000). Genuinely Apple-Development-signed, not ad-hoc.

Entitlements (codesign-verified post-build):
- **App:** `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope` (+ Xcode-Debug `get-task-allow`).
- **Helper:** `app-sandbox`, `inherit`, `files.user-selected.read-write`, `cs.allow-jit`, `cs.allow-unsigned-executable-memory` (+ `get-task-allow`).

## What was built

Throwaway signed project at `/tmp/InheritWriteSpike/` (**not committed**). Built with xcodegen → xcodebuild, real-signed as above, copied to `~/Desktop/InheritWriteSpike.app` and run from there (signed sandboxed apps refuse to launch from `/private/tmp` — Task 6.5 gotcha). The vendored Node (`Resources/node-runtime/bin/node`, v24.15.0, Node-Foundation-signed `TeamIdentifier=HX7739G8FX`) was co-bundled into the helper.

- **App:** picks `~/Desktop/inherit-spike-target/` (pre-created with `existing.txt`) via `NSOpenPanel`. Powerbox panel driven non-modally (`panel.begin {…}`) and committed with a System-Events Return keystroke (programmatic `-[NSSavePanel ok:]` raised an NSException — recorded gotcha). The app then `url.bookmarkData([.withSecurityScope])` → persists → re-resolves → `startAccessingSecurityScopedResource()` (returned **true** in-app), HOLDING the grant. It passes the **plain absolute path** (a String) to the helper over `NSXPCConnection`.
- **Helper:** an XPC service that does **not** resolve any bookmark and does **not** call `startAccessing…`. Given the plain path it (a) tries to read+write the dir *itself* (diagnostic), then (b) spawns the test child via `Process()` with `currentDirectoryURL` = the granted path. Reports exit code + captured stdout/stderr per test.

Real-home gotcha (recorded): inside the sandbox `NSHomeDirectory()` returns the container, so the panel was initially pointed at a non-existent `…/Containers/…/Data/Desktop/…`. Fixed by resolving the true home via `getpwuid(getuid())->pw_dir`.

## Tests A / B / C — verbatim output

The app confirmed it holds the grant before any test:
```
[app] scoped bookmark: 716 bytes
[app] re-resolved scoped bookmark: /Users/dwk/Desktop/inherit-spike-target stale=false
[app] startAccessing in-app (HOLDING GRANT): true
```

Each test also probes whether the **helper itself** can touch the path (isolates "did the grant reach the helper at all" from "did it propagate to the helper's child").

### TEST A — subdir create + write + read (shell), GRANT HELD — expect exit 0 + "hello-inherit"
```
[helper] test A | cwd=/Users/dwk/Desktop/inherit-spike-target
[helper] DIRECT readdir FAILED (helper has no read access)
[helper] DIRECT write FAILED: You don’t have permission to save the file “helper-direct-write.txt” in the folder “inherit-spike-target”.
[helper] /bin/sh -c '...' exit=1
stdout/stderr:
shell-init: error retrieving current directory: getcwd: cannot access parent directories: Operation not permitted
job-working-directory: error retrieving current directory: getcwd: cannot access parent directories: Operation not permitted
mkdir: deep: Operation not permitted
```
**Verdict A: FAIL.** Even with the grant held in the app, the helper can neither read nor write the folder, and its shell child cannot even `getcwd()` it, let alone `mkdir deep/`.

### TEST B — Node write into `node_modules/` subdir (real npm workload), GRANT HELD — expect "ok" + exit 0
```
[helper] test B | cwd=/Users/dwk/Desktop/inherit-spike-target
[helper] DIRECT readdir FAILED (helper has no read access)
[helper] DIRECT write FAILED: You don’t have permission to save the file “helper-direct-write.txt” in the folder “inherit-spike-target”.
[helper] node=.../InheritWriteSpike.app/Contents/XPCServices/ProbeHelper.xpc/Contents/Resources/node-runtime/bin/node
[helper] node -e '...' exit=1
stdout/stderr:
node:fs:1350
  const result = binding.mkdir(
                         ^
Error: EPERM: operation not permitted, mkdir 'node_modules/.x'
    at Object.mkdirSync (node:fs:1350:26)
    ...
  errno: -1,
  code: 'EPERM',
  syscall: 'mkdir',
  path: 'node_modules/.x'
}
Node.js v24.15.0
```
**Verdict B: FAIL.** Node launches fine (the binary runs — consistent with the Node sub-spike) but `mkdir('node_modules/.x')` is `EPERM`. The grant did not reach Node via the helper.

### TEST C — negative control: app RELEASES the grant, retry Test A — expect FAILURE
```
[app] stopAccessingSecurityScopedResource() — GRANT RELEASED
[helper] test C | cwd=/Users/dwk/Desktop/inherit-spike-target
[helper] DIRECT readdir FAILED (helper has no read access)
[helper] DIRECT write FAILED: You don’t have permission to save the file “helper-direct-write.txt” in the folder “inherit-spike-target”.
[helper] /bin/sh -c '...' exit=1
stdout/stderr:
shell-init: error retrieving current directory: getcwd: cannot access parent directories: Operation not permitted
job-working-directory: error retrieving current directory: getcwd: cannot access parent directories: Operation not permitted
mkdir: deep: Operation not permitted
```
**Verdict C: FAIL (as expected for a negative control).** With the grant released, access is still denied — identical to A. Because A (grant held) and C (grant released) are **byte-identical**, the held grant made **no difference**, which is the decisive signal: the helper-side access does not come from the app's grant at all.

App's own summary line:
```
[app] VERDICT-A status=1 (0=pass)
[app] VERDICT-B status=1 (0=pass)
[app] VERDICT-C status=1 (NONZERO=correct negative control)
```

### Unified-log sandbox capture
`log show --last 5–6m` filtered for `ProbeHelper` / `sh` / `node` / `Sandbox` / `deny` / `inherit-spike` surfaced **no kernel `Sandbox: … deny` lines**. As in Task 0 and 6.5, the denials manifest as userspace `EPERM` / Cocoa "you don't have permission" (container scope), not kernel sandbox-violation log lines, and `log show` persistence for short-lived sandboxed children is unreliable on this OS. The XPC replies above (`EPERM`, "no permission", `getcwd … Operation not permitted`) are the authoritative evidence and are unambiguous.

## Overall VERDICT

**FAIL.** `com.apple.security.inherit` does **not** extend the app's held security-scoped grant to the XPC helper — for writes, reads, or subdirectories. The grant never reaches the helper process, so there is nothing for the helper's spawned child to inherit either.

### Why (interpretation — and why this differs from Task 0)

The corrected design assumed: app holds grant → `inherit` carries it to the helper → helper passes a plain path to Node. **This conflates two different inheritance relationships.**

`com.apple.security.inherit` makes a process that a sandboxed process **directly spawns** (`Process()` / `posix_spawn`) inherit *that spawning process's* sandbox + its currently-held extensions. It is a parent→child mechanism along the actual spawn tree.

But the **XPC helper is not a child of the app.** An `XPCService` is launched **on demand by launchd**, in its own sandbox container (`io.dwk.inheritwritespike.probe`), with launchd as its parent. The app's security-scoped extension is bound to the *app's* process and its container; it is not transferred across the XPC connection, and `inherit` on the helper conveys *launchd's* context, not the app's grant. Hence the helper has zero access to the user-selected path (DIRECT read/write both FAILED), and its `Process()` children — which *would* correctly inherit from the helper via `inherit` — inherit "no access".

This is consistent with, not contradictory to, Task 0: there the access the helper-children enjoyed came from the **helper's own** sandbox state in that spike's flow, *not* from the app's grant crossing the XPC boundary. Task 6.6 isolates the app→helper hop specifically and shows it does not carry the grant. (Task 6.5 already proved the other route — helper resolving the scoped bookmark itself — also fails. So neither "inherit the app's grant" nor "re-resolve in the helper" works.)

## Task 7 implication — fd-passing REQUIRED

The inherit-path design (Task 6.5 Option B) is **ruled out**. Task 7 must adopt **fd-passing** (Task 6.5 Option A). Recommended mechanism:

1. **App owns and resolves the scope.** The app holds the `.withSecurityScope` app-scoped bookmark on `SiteStore.Site.bookmarkData`, re-resolves it each launch (works in-app: `startAccessing… == true`), and keeps `startAccessingSecurityScopedResource()` live for the duration of any helper operation on that site.
2. **App opens the site root as a directory file descriptor** — `open(sitePath, O_RDONLY | O_DIRECTORY)` (or an `NSFileHandle` / `FileHandle(forReadingAtPath:)` for the dir) — *while the scope is held*. A file descriptor obtained under an active scope carries its access rights with it.
3. **App passes the fd to the helper over XPC.** File descriptors transfer across `NSXPCConnection` (via `NSFileHandle` arguments in the remote interface, or a raw fd wrapped in `xpc_fd_create` on the C XPC API). The transferred fd retains the access it was opened with — the helper does **not** need its own scope grant or bookmark.
4. **Helper operates relative to the received dir fd.** `fchdir(fd)` then relative paths, or the `*at()` family (`openat`, `mkdirat`, `unlinkat`) rooted at the dir fd. For spawning Node/Astro/npm: `fchdir(dirfd)` in the child's pre-exec setup (or set the child's cwd via the fd) so the whole subtree (`dist/`, `node_modules/`, `.wrangler/`, `public/images/`) is reachable through the inherited fd's rights — these flow to the `Process()` child via the normal fd-inheritance + `inherit` entitlement, which DOES work along the helper→child spawn tree.
   - **Verify before committing Task 7:** that an fd opened under scope in the app and passed over XPC actually grants the helper *write into subdirectories* (not just the dir node), and that a `Process()` child of the helper (`fchdir`'d to that fd) can `mkdir`/write throughout the tree. This is the one piece this spike did not prototype on the fd side; it is the load-bearing assumption of the fd-passing design and should get a short confirm before Task 7 implementation, OR be proven incrementally as the first commit of Task 7.
5. **Remove the inherit-path artifacts:** drop `SpawnSpec.workingDirectoryBookmark` and the helper-side `resolveSpawn` bookmark-resolution code. The helper should never see a bookmark — only fds (and plain paths for logging/labels only).

## What was NOT tested

- **fd-passing itself.** This spike *disproves* the inherit-path design; it does not yet *prove* the fd-passing replacement. The fd round-trip + subtree-write + `Process()`-child-via-fchdir chain needs its own quick confirm (see Task 7 implication step 4) before Task 7 is locked.
- **Distribution / Mac App Store provisioning-profile signing.** Development cert + `get-task-allow`, local run. The failure is rooted in process topology (XPC helper is launchd-spawned, not app-spawned), which a Distribution profile cannot change, so reproduction under MAS signing is essentially certain — but Task 12 should still confirm on a profiled build.
- **Files OUTSIDE the granted tree.** Only the selected folder + subdirs were exercised.
- **Very long-lived grant** (the multi-minute `astro dev` case): whether `startAccessing…` held open across a long-running helper operation behaves the same. Expected to, but untested.
- **macOS 14 / 15.** This machine is macOS 26.5 only. The launchd-spawned-XPC-service topology and the inherit semantics have been stable for years, so reproduction on 14/15 is very likely.
- **Passing the path as a bookmark for the helper to resolve** — already ruled out by Task 6.5; not re-litigated.

## Status

**DONE.** Question answered with a real, observed, Apple-Development-signed end-to-end run plus a meaningful negative control (grant held vs released produced byte-identical denial). Verdict: **FAIL** — `inherit` does not extend the app's grant to the helper or its child. Task 7 must use fd-passing (Task 6.5 Option A), with a short fd-round-trip confirm as its first step. The throwaway spike project at `/tmp/InheritWriteSpike/` is not committed.
