# Phase 10.1 — Task 0 Spike Notes (Sandboxed XPC + /usr/bin/git)

**Date:** 2026-05-27
**Source plan:** `docs/specs/2026-05-27-sandboxed-app-store-plan.md` (Task 0)
**Outcome:** DONE_WITH_CONCERNS — core capability works, but the *exact* approach in the plan (`/usr/bin/git`, security-scoped bookmark via XPC) does **not** work as-stated. Path forward exists; plan needs amendment before Task 1.

## TL;DR

- A sandboxed XPC helper **can** spawn a git process and read user-selected directories. ✅
- It **cannot** spawn `/usr/bin/git` — that's the Apple `xcrun` shim, which is explicitly blocked inside `app-sandbox`. ❌
- The fix: use `/Library/Developer/CommandLineTools/usr/bin/git` (or `/Applications/Xcode.app/.../usr/bin/git`) directly — but this depends on the user having the Command Line Tools or Xcode installed, and these paths aren't a stable redistributable. Likely needs libgit2 OR a bundled `git` binary in the Anglesite-app resources.
- Security-scoped bookmark resolution **across processes** with `URL(resolvingBookmarkData:options:.withSecurityScope)` fails with `NSCocoaErrorDomain 259` under **ad-hoc signing**. Plain (non-scoped) bookmarks transfer fine; the helper still reaches the folder via `com.apple.security.inherit` and the user-selected grant. **Whether `.withSecurityScope` works with proper Apple Development signing is unverified** — see Open Questions.

This is a meaningful course correction for the milestone but **not** a hard stop. The libgit2/SwiftGit2 fallback named in the plan is one option; bundling `git` is another. Either way, **Phase 10.1 should not assume `/usr/bin/git` is reachable from the sandbox.**

## Environment

```
$ sw_vers
ProductName:		macOS
ProductVersion:		26.5
BuildVersion:		25F71

$ xcodebuild -version
Xcode 26.5
Build version 17F42

$ security find-identity -v -p codesigning
     0 valid identities found
```

**No Apple Development cert installed.** All builds in this spike used **ad-hoc signing** (`CODE_SIGN_IDENTITY = -`), the same approach the existing Anglesite-app Debug config uses today. Hardened runtime auto-disabled by Xcode for ad-hoc.

## What was built

A throwaway project at `/tmp/SandboxSpike/` (not committed, will be deleted):

- `SandboxSpike.app` — minimal SwiftUI window with a "Pick folder & run git status" button. Sandbox + `files.user-selected.read-write` + `files.bookmarks.app-scope`.
- `ProbeHelper.xpc` — embedded XPC service. Sandbox + `inherit` + `files.user-selected.read-write` + `network.client`. Exposes one `Probe` protocol method.
- Built with xcodegen → xcodebuild. Both binaries ad-hoc signed (`-`).

Codesign-verified entitlements (post-build):

```
$ codesign -d --entitlements - .../ProbeHelper.xpc
  com.apple.security.app-sandbox: true
  com.apple.security.files.user-selected.read-write: true
  com.apple.security.get-task-allow: true   ← injected by Xcode for Debug
  com.apple.security.inherit: true
  com.apple.security.network.client: true
```

App and helper land in separate sandbox containers as expected:

```
~/Library/Containers/io.dwk.sandboxspike.app
~/Library/Containers/io.dwk.sandboxspike.probe
```

## Test methodology

- Launched the app, used System Events / AppleScript to click the button.
- In the NSOpenPanel, used Cmd+Shift+G to enter `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app` directly (no user click needed — same effect as a manual selection).
- App created two bookmarks from the panel-returned URL:
  - **scoped:** `URL.bookmarkData(options: [.withSecurityScope], ...)` → 804 bytes
  - **plain:** `URL.bookmarkData(options: [], ...)` → 972 bytes
- App also verified `url.startAccessingSecurityScopedResource()` succeeded *in-app* (it did).
- Sent both bookmarks over `NSXPCConnection` to `ProbeHelper.xpc`.
- Helper attempted multiple resolution paths and several spawn experiments.

## Verbatim output (final run)

```
[app] selected: /Users/dwk/Developer/github.com/Anglesite/Anglesite-app
[app] scoped bookmark: 804 bytes
[app] plain bookmark: 972 bytes
[app] startAccessing in-app: ok
[app] calling helper...
[helper] scoped: 804 bytes, plain: 972 bytes
[helper] plain bookmark resolved: /Users/dwk/Developer/github.com/Anglesite/Anglesite-app stale=false
[helper] scoped/.withSecurityScope FAILED (expected): The file couldn't be opened because it isn't in the correct format.
[helper] startAccessing: false

=== /usr/bin/git status ===
exit=1
xcrun: error: cannot be used within an App Sandbox.

=== /usr/bin/git status with DEVELOPER_DIR ===
exit=1
xcrun: error: cannot be used within an App Sandbox.

=== /Library/Developer/CommandLineTools/usr/bin/git status ===
exit=0
On branch main
Your branch is up to date with 'origin/main'.

nothing to commit, working tree clean

=== /bin/ls -la ===
exit=0
total 72
drwxr-xr-x  22 dwk  staff   704 May 27 21:10 .
...
drwxr-xr-x@ 14 dwk  staff   448 May 27 21:58 .git
...
```

## Findings

### Finding 1 (blocking the planned approach): `/usr/bin/git` is unreachable from a sandbox

`/usr/bin/git` on modern macOS is the Apple developer-tools shim. It immediately execs into `xcrun` to find the active toolchain's real git binary. `xcrun` **explicitly refuses to run inside App Sandbox** — this is by design and has been the behaviour for years.

Setting `DEVELOPER_DIR=/Library/Developer/CommandLineTools` in `Process.environment` does **not** bypass it; the failure happens in `xcrun` itself before it reads the env.

Implication for the build plan: every place in the spec that talks about "the helper runs `/usr/bin/git …`" needs to be rewritten. Options, ranked roughly by effort:

1. **Spawn the real git binary directly** — e.g. `/Library/Developer/CommandLineTools/usr/bin/git`. Pros: minimal code change. Cons:
   - Path is not stable across user setups (some users have only Xcode, some have CLT, some have both, some have neither).
   - On a fresh Mac with no developer tools, this path does not exist. A Mac App Store user has no reason to have it.
   - Requires probing both paths and falling back; adds error states the chat panel needs to handle.
2. **Bundle `git` in the app** — copy the CLT git binary (statically linked-ish) into `Anglesite.app/Contents/Resources/`. Pros: zero dependency on user toolchain. Cons: licensing/signing/re-signing churn, plus git has a sprawling support tree (`git-core/*`, `git-credential-osxkeychain`, `gitexec` directory, `templates/`, locale files). Bundling a working git is a project in itself.
3. **libgit2 / SwiftGit2** — the fallback named in the plan. Reads/writes the repo directly through the libgit2 API. No spawn needed. Pros: no `xcrun` issue, fully sandbox-clean. Cons: ~300-500 line Swift rewrite of every git call site in the helper; libgit2 is missing a handful of features (sparse checkout, git LFS, etc.) but Anglesite-app's usage is shallow (status, add, commit, push). The plan's risk callout is accurate.
4. **Skip git entirely in MAS build** — make `git` opt-in via the chat panel's existing pluggable command surface. The MAS build then doesn't claim git support. Pros: smallest scope. Cons: shrinks the MAS feature set noticeably; probably not acceptable.

My recommendation: **(3) libgit2/SwiftGit2 for the MAS build**, hidden behind the `SupervisorBackend` protocol the plan already proposes. The InProcessBackend keeps using `Process()` + `/usr/bin/git` (already works in the non-MAS dev build). The XPCBackend gets a libgit2 implementation. This is exactly what the plan's "Risk" section flagged as the fallback; the spike confirms it's now the *primary* path, not the contingency.

### Finding 2 (signing-related, less certain): security-scoped bookmark resolution fails across XPC under ad-hoc signing

`URL(resolvingBookmarkData: scopedData, options: .withSecurityScope, ...)` in the helper throws `NSCocoaErrorDomain 259` ("The file couldn't be opened because it isn't in the correct format.").

The `log show` output shows the helper does contact `com.apple.scopedbookmarksagent.xpc` during resolution, and there's a sqlite error trying to open `/private/var/db/DetachedSignatures`:

```
ProbeHelper: (libsqlite3.dylib) cannot open file at line 51044 of [f0ca7bba1c]
ProbeHelper: (libsqlite3.dylib) os_unix.c:51044: (2) open(/private/var/db/DetachedSignatures) - No such file or directory
```

`DetachedSignatures` is part of the macOS code-signing infrastructure that `scopedbookmarksagent` uses to validate that the bookmark's creator process matches a signed-and-trusted identity. With ad-hoc signing there's no stable Team ID for the bookmark to remember, so cross-process resolution fails.

**This finding has a confounding variable:** ad-hoc signing. With a real Apple Development cert (and a Team ID), the bookmark would likely carry that identity and resolve in the helper. I could not verify this on this machine because no signing cert is installed.

**Workaround that works today:** the helper uses `com.apple.security.inherit`, which gives it the same powerbox-granted access the app has for user-selected files. The user-selection flows through implicitly. The helper resolves a *plain* (non-scope) bookmark to get the path, and `/bin/ls` and `/Library/Developer/CommandLineTools/usr/bin/git` can read the directory. **No explicit scope resolution is required for the operations the spike tested.** Whether this holds for write operations and for files outside the immediately-selected directory tree (subdirs of `~/Sites/foo/`) needs more probing.

This may or may not affect the build plan. The plan's design has the app create a bookmark and store it; the helper resolves it later. If `inherit` covers everything we need, the bookmark is redundant. If we need persistent access across launches (very likely, for the "open last site automatically" flow), we need bookmarks, and bookmarks need a signed app.

**Action for the user:** before Task 7 (security-scoped bookmarks in SiteStore), do a one-day sub-spike with a real Apple Development cert. If `.withSecurityScope` resolution works with proper signing, the plan stands. If not, this is a second course correction.

### Finding 3 (positive — the core question): a sandboxed XPC helper *can* execute a child process and read a user-selected folder

Modulo the binary-path issue, the spike confirmed:

- `Process()` works inside a sandboxed XPC service. (`/bin/ls` and the direct-path git both ran.)
- `currentDirectoryURL` set to a user-selected path works.
- Standard pipes capture stdout/stderr.
- No additional entitlement was required beyond `com.apple.security.inherit` and `com.apple.security.files.user-selected.read-write`.

This is the load-bearing question Phase 10.1 was built around, and the answer is **yes**.

## Things that surprised me

- I expected `DEVELOPER_DIR=/Library/Developer/CommandLineTools` to redirect `/usr/bin/git`. It doesn't; xcrun blocks based on sandbox status, not on DEVELOPER_DIR resolution.
- I expected `.withSecurityScope` cross-process to "just work" given the inherit entitlement. The detached-signature requirement under code signing is subtle and worth flagging in the design doc.
- No explicit sandbox-violation log lines from the kernel sandbox subsystem for the xcrun block — xcrun handles the gate itself in userspace. (`log show --predicate 'process == "xcrun"'` would presumably show this, but the kernel-level Sandbox subsystem stays quiet.)

## Console / log warnings observed

`log stream --predicate 'eventMessage CONTAINS "sandbox"'` was attempted but the shell wrapper rejected the command; switched to `log show` after the fact. Filtered for `process == "ProbeHelper"`:

- Many normal XPC/RBS/SkyLight startup messages.
- The DetachedSignatures sqlite errors (quoted above) — directly relevant to Finding 2.
- No `kernel: Sandbox: ProbeHelper(...) deny ...` lines, which would have indicated a kernel-level sandbox violation. The xcrun block is userspace, not kernel.

## What was NOT tested

- macOS 14 and macOS 15 — this machine is macOS 26.5. The plan explicitly noted this would be deferred. **User needs to repeat this spike on a 14.x and a 15.x VM/box** before locking the deployment target. The xcrun-sandbox restriction has been in place since macOS 10.14-ish, so Finding 1 will reproduce on 14 and 15 with very high confidence. Finding 2 may behave differently — older bookmark agents had different validation rules.
- Signed builds. Re-run with a real Apple Development cert is required to confirm whether `.withSecurityScope` cross-process resolution works under non-ad-hoc signing.
- Mac App Store distribution profile. The spike used a development-style entitlement set; a Distribution profile may require additional entitlements (e.g. App Sandbox temp exceptions for the embedded Node runtime, which the existing app already vendors). Task 12 (Release pipeline + docs) will need to verify this.
- Embedded Node binary. The spike tested `/usr/bin/git` and `/bin/ls`; it did NOT test the vendored Node binary at `Resources/node-runtime/`. Node is the thing that *actually* matters for Anglesite-app's runtime, and Node-spawn behaviour inside a sandboxed XPC service hasn't been validated yet. This is a likely follow-up sub-spike (and it should not be assumed to work just because git did — Node ships without xcrun-shimming, so it has a better chance, but `Process()` against a vendored, re-signed Node binary inside the XPC sandbox needs its own confirmation).
- Write operations. Spike only tested read (`git status`, `ls -la`).
- Network. `com.apple.security.network.client` is set on the helper but no network calls were exercised.

## Recommendation to the milestone owner

Phase 10.1 should proceed, with these amendments to the plan:

1. **Replace "spawn `/usr/bin/git`" with "use libgit2/SwiftGit2 in the XPCBackend"** — adjust the design doc and the Task 8 (Migrate direct Process() calls) bullet list accordingly. Add a new task for libgit2 integration before Task 8 (e.g. "Task 8a: SwiftGit2 dependency + git wrapper").
2. **Before Task 7 (security-scoped bookmarks)** — do a half-day sub-spike with an Apple Development cert installed, to confirm `.withSecurityScope` cross-process resolution works under real signing. If it does, no change. If it doesn't, design bookmark passing differently (e.g. resolve in the app and pass an open NSFileHandle to the helper).
3. **Before Task 11 (MAS smoke fixture)** — separate sub-spike for the **embedded Node binary** inside the sandboxed XPC helper. Confirm Node spawn, network, and exit-code propagation. Don't extrapolate from this git spike.
4. **User to repeat this exact spike on macOS 14 and macOS 15** at any point before the GA target ships. The spike project is disposable and quick to rebuild; the user can clone the structure from this notes file.

## Status

**DONE_WITH_CONCERNS.** Spike completed. Core finding favourable. Two specific course corrections required (libgit2 over `/usr/bin/git`; verify signed-build bookmark behaviour). No reason to stop the milestone; one reason to amend the plan before Task 8.
