# Phase 10.1 — Task 6.7 Sub-Spike Notes (app spawns children directly — do they inherit the scoped grant?)

**Date:** 2026-05-28
**Gates:** the entire MAS architecture — whether the XPC helper (Tasks 4/5/6) is needed at all
**Predecessors:**
- `docs/specs/2026-05-27-sandboxed-app-store-spike-notes.md` (Task 0 — helper-child *reads* the top of a user-selected folder)
- `docs/specs/2026-05-28-bookmark-signed-subspike-notes.md` (Task 6.5 — helper CANNOT resolve a `.withSecurityScope` bookmark; bookmark must be resolved in the APP)
- `docs/specs/2026-05-28-fd-passing-subspike-notes.md` (Task 6.6 — neither fd-passing NOR plain `inherit` carries the app's held grant to the **XPC helper** or its children; "everything fails" for the helper)
- `docs/specs/2026-05-28-node-sandbox-subspike-notes.md` (vendored Node runs inside a sandboxed process under `cs.allow-jit`)

**Outcome:** **DONE.** **VERDICT: CONFIRMED — a sandboxed, real-signed app with NO XPC helper can spawn direct children (`/bin/sh` *and* the bundled Node) that write absolute paths deep inside a user-selected folder, by inheriting the app's active security-scoped grant.** S0–S4 all PASS; the decisive negative control (S6 — a never-granted sibling path) FAILS with EPERM for both the app and its children, proving access is grant-scoped, not ambient. **Recommendation: drop the XPC helper for MAS; revert Tasks 4/5/6.**

## The question

The prior spikes proved the grant does NOT reach a **separate XPC helper** (a different launchd-spawned process) by any mechanism short of sandbox-extension tokens (private SPI). But a security-scoped grant is, on macOS, inherited by the **direct child processes of the process that holds it** — standard sandbox-extension inheritance. The helper failed precisely because it is not a child of the grant-holding app; it is its own launchd-spawned process. A process the **app** spawns via `Process()` *is* such a direct child. If that child inherits the grant for absolute-path writes throughout the granted subtree, then Anglesite's MAS build needs no helper at all: the sandboxed app spawns Node/Astro/wrangler directly (exactly as the non-sandboxed DevID build already does) while holding the per-site grant. This spike tests that hypothesis empirically rather than assuming it.

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

Signing: `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY="Apple Development: dwk@mac.com (KH7H8Y25RT)"`, `DEVELOPMENT_TEAM=UX3L9R8RSL`, hardened runtime ON, no provisioning profile (development-signed local run). The bundled Node was re-signed with the **app's own** identity (the MAS re-sign scenario).

### `codesign -dv --verbose=4` proof — really Apple-Development-signed, NOT ad-hoc

```
===== APP =====
Identifier=io.dwk.appspawn.app
CodeDirectory v=20500 size=447 flags=0x10000(runtime) hashes=3+7 location=embedded
Executable Segment flags=0x1
Authority=Apple Development: dwk@mac.com (KH7H8Y25RT)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=UX3L9R8RSL
# `codesign -dvvv` contains NO "adhoc" string.

===== BUNDLED NODE (Contents/Resources/node-runtime/bin/node) =====
Identifier=node
CodeDirectory v=20500 size=232752 flags=0x10000(runtime) hashes=7263+7 location=embedded
Authority=Apple Development: dwk@mac.com (KH7H8Y25RT)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=UX3L9R8RSL
```

Both app and bundled Node carry the full Apple-Development chain + `TeamIdentifier=UX3L9R8RSL` + hardened-runtime flag (0x10000). Genuinely Apple-Development-signed; the foreign Node-Foundation Team ID (HX7739G8FX) was replaced by re-signing Node to our identity, as the MAS packaging step will do.

Entitlements (codesign-verified post-build):
- **App:** `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, `cs.allow-jit`, `cs.allow-unsigned-executable-memory`.
- **Bundled Node:** `app-sandbox`, `inherit`, `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.disable-library-validation`. (`inherit` is required so the Node child runs **inside the app's sandbox** and thus inherits the grant; the JIT pair is required for V8 to reserve its CodeRange under hardened runtime — see the S3 gotcha below.)

## What was built

Throwaway SwiftUI app, **NO XPC service** (the whole point), at `/tmp/AppSpawnSpike/` (**not committed**). xcodegen → xcodebuild, real-signed as above; bundled Node copied into `Contents/Resources/node-runtime/bin/node` and re-signed; the whole app re-signed so the bundle seal includes Node. Copied to `~/Applications/AppSpawnSpike.app` and run from there (signed sandboxed apps refuse to launch from `/private/tmp` — Task 6.5 gotcha).

App flow: `NSOpenPanel` → select a fresh, isolated `~/Desktop/appspawn-target-runN` (pre-created empty + `existing.txt`) → `startAccessingSecurityScopedResource()` (held for S0–S4) → run the matrix. Every spawn is a **DIRECT child** of the app via `Process()`. Output mirrored to the app's container `Documents/appspawn-report.txt`.

### Gotchas recorded (for Task 7 / future spikes)

- **The sandboxed app cannot list `~/Desktop` to auto-discover the target** (no grant yet). The harness passes the target path via the `APPSPAWN_TARGET` env var (`open --env`) / a file in the app's own container, used only to seed `panel.directoryURL` so the default **Grant** button grants the right folder. (Same class of issue as the FD spike's pre-create-outside-the-sandbox note.)
- **Bundled Node OOMs at launch without JIT entitlements on Node itself.** First run, Node (re-signed with only `--options runtime`, no entitlements) aborted: `Fatal process out of memory: Failed to reserve virtual memory for CodeRange` (V8 `Heap::SetStackStart` → `FatalOOM`). This is NOT a sandbox/folder denial — it is hardened-runtime blocking V8's JIT region. Fix: sign the **Node binary** with `com.apple.security.cs.allow-jit` + `com.apple.security.cs.allow-unsigned-executable-memory` (and `com.apple.security.inherit` + `app-sandbox` so it joins the app's sandbox). After that, S3/S4 PASSED. The prior Node sub-spike did not hit this because it was ad-hoc (hardened runtime auto-disabled); under a real cert with hardened runtime, the JIT entitlements on Node are load-bearing. **Carry these entitlements on the vendored Node in the MAS re-sign step.**
- **`open` reuses a live instance.** A still-running prior instance is merely activated, not relaunched, so a fresh run needs `pkill -9 -f AppSpawnSpike.app` then `open -n`.
- **`stopAccessingSecurityScopedResource()` does NOT revoke a Powerbox user-selection grant for the process lifetime** — see S5 below. Use a *never-granted* path (S6) as the negative control, not stop-then-write.

## Test matrix — verbatim output (the conclusive run, run4)

App pre-amble:
```
[app] pid=61557 euid=501
[app] nodePath=…/AppSpawnSpike.app/Contents/Resources/node-runtime/bin/node exists=true
[app] selected: /Users/dwk/Desktop/appspawn-target-run4
[app] startAccessingSecurityScopedResource() = true
```

| Test | What it proves | Result | Key verbatim output |
|---|---|---|---|
| **S0** — app in-process abs write (baseline) | grant is active in-app | **PASS** | `[S0] PASS — app in-process write to …/deep/sub/s0.txt readback=s0` |
| **S1** — direct child `/bin/sh`, ABSOLUTE path (**the key test**) | direct child inherits grant for abs writes | **PASS** | `[S1] PASS — /bin/sh abs write. exit=0 stdout="s1" stderr=""` |
| **S2** — direct child `/bin/sh`, `currentDirectoryURL=<abs>`, relative writes (matches `AstroDevServer`) | cwd-relative writes work too | **PASS** | `[S2] PASS — /bin/sh cwd=…/run4 relative write. exit=0 stdout="s2" stderr=""` |
| **S3** — direct child BUNDLED Node, ABSOLUTE path (**the real workload**) | bundled Node does abs-path FS ops in the granted tree | **PASS** | `[S3] PASS — bundled node abs write. exit=0 stdout="S3 s3" stderr=""` |
| **S4** — long-lived child Node, 2 writes 3 s apart (mimics `astro dev`) | grant stays valid for a long-running child | **PASS** | `[S4] PASS — long-lived node 2 writes 3s apart. exit=0 stdout="S4a s4a\nS4b s4b" stderr=""` |
| **S5app** — APP in-process write to a fresh path AFTER `stopAccessing` | (control attempt — see note) | unexpected-success | `[S5app] FAIL(unexpected-success!) — app in-process wrote …/fresh5/s5app.txt after stopAccessing` |
| **S5child-fresh / S5child-reuse** — child writes AFTER `stopAccessing` | (control attempt — see note) | unexpected-success | `exit=0 stdout="s5cf"` / `exit=0 stdout="s5"` |
| **S6app** — APP write to a NEVER-granted sibling folder (**decisive control**) | access is grant-scoped, not ambient | **PASS (expected-fail)** | `[S6app] PASS(expected-fail) … NSCocoaErrorDomain Code=513 "You don't have permission…" … NSPOSIXErrorDomain Code=1 "Operation not permitted"` |
| **S6child** — direct child write to a NEVER-granted sibling folder (**decisive control**) | child has no ambient access either | **PASS (expected-fail)** | `[S6child] PASS(expected-fail) … exit=1 stderr="mkdir: /Users/dwk/Desktop/appspawn-NEVER-61557: Operation not permitted"` |

On-disk confirmation (grant still observable): everything written by S0–S4 (app, `sh`, Node) landed under `…/run4/deep/sub/` (`s0..s4b.txt`); the **never-granted** `~/Desktop/appspawn-NEVER-61557` was never created. `log show --last 4m` for `AppSpawnSpike`/`node`/`sh` surfaced **no kernel `Sandbox: … deny` lines** — denials manifest as userspace EPERM / Cocoa-513 (consistent with Tasks 0 / 6.5 / 6.6).

### On S5 (why it is not the control, and why that is fine)

S5 attempted the spec's "stop the grant, then write should fail" control. It did NOT fail — but **S5app shows the APP ITSELF still wrote** after `stopAccessingSecurityScopedResource()`, to a brand-new untouched path. So this is not a child-inheritance artifact: `stopAccessing` only decrements the security-scoped *bookmark* refcount; the **Powerbox user-selection grant persists for the whole process lifetime** regardless. The spec anticipated S5 as the proof-of-grant control, but on this OS it cannot distinguish "grant via inheritance" from "ambient app access." **S6 is the correct negative control** and it behaves exactly as required: a folder the user never selected is EPERM for both the app and its children, while the selected folder is writable by both. That contrast is the airtight proof that the children's access flows from the user's grant on the selected path, inherited by the direct child — not from any ambient process permission.

## VERDICT

**CONFIRMED.** A sandboxed, real-Apple-Development-signed app with **no XPC helper** spawns direct children — `/bin/sh` (S1 absolute, S2 cwd-relative) and the **bundled, re-signed Node** (S3 absolute, S4 long-lived) — that create directories and write files **throughout** a user-selected folder's subtree. The access is **scoped to the granted path** (S6: a never-granted sibling is EPERM for app and child alike), i.e. it is the app's security-scoped grant, **inherited by the direct child**, that provides it. No difference between `sh` and Node once Node carries the JIT+inherit entitlements; `currentDirectoryURL` (S2) is not required — absolute paths (S1/S3, the real Node/Astro/npm/wrangler pattern) work directly. This is the exact opposite of the **XPC-helper** result (Task 6.6), and confirms the hypothesis that the helper failed because it is a *separate process*, not a *child* of the grant-holder.

### Architecture recommendation for MAS: DROP THE HELPER

- **MAS uses the in-process `Process()` spawn path** (essentially the existing `InProcessBackend` from Task 3), with the app holding a per-site security-scoped grant (resolved in the app — Task 6.5) for the lifetime of the spawned children. Node/Astro/npm/wrangler are spawned **directly by the app** and inherit the grant for absolute-path FS work throughout the site folder.
- **No XPC helper, no XPC protocol, no fd-passing, no sandbox-extension tokens, no private SPI** → **no App-Store-review risk** from any of those mechanisms.
- **Revert Tasks 4, 5, and 6? YES.** The helper (Task 5), the `AnglesiteHelperProtocol` XPC interfaces (Task 4), and `XPCBackend` (Task 6) are not needed for MAS and should be reverted/removed for that target. Keep the `SupervisorBackend` protocol (Task 2) and `InProcessBackend` (Task 3) — the MAS target simply uses `InProcessBackend` plus the app-held grant.
- **Carry forward to Task 7/11/12:** (a) resolve the per-site bookmark **in the app** and hold the scope across the whole supervised-process lifetime; (b) re-sign the vendored Node with the **app's own Team ID** AND with `cs.allow-jit` + `cs.allow-unsigned-executable-memory` + `inherit` + `app-sandbox` (the S3 OOM proves these are load-bearing under real hardened-runtime signing, unlike the ad-hoc Node sub-spike); (c) the same entitlements/inherit pattern applies to any other bundled executable the app spawns.

## What was NOT tested

- **Distribution / Mac App Store provisioning-profile signing.** Development cert + `get-task-allow`, local run. Security-scoped-grant *inheritance by direct children* is a long-stable kernel-sandbox property that a Distribution profile does not change, so reproduction under MAS signing is expected — but Task 11/12 must confirm on a profiled build, and must specifically confirm the re-signed bundled Node passes App Store review and library validation under the real profile.
- **macOS 14 / 15.** This machine is macOS 26.5 only. Inheritance semantics have been stable for years; reproduction on 14/15 is very likely but unverified.
- **The real `npm` / `wrangler` / full `astro dev` workloads.** Tests used `/bin/sh` and `node -e` snippets (abs `mkdirSync`/`writeFileSync`/`readFileSync`, plus a 3 s long-lived child). The actual pipeline resolves modules from the bundled `lib/node_modules`, watches files (FSEvents/kqueue), spawns its own grandchildren, and serves a long-lived port. Grandchild inheritance (Node → its child processes), file-watching under sandbox, and multi-minute lifetimes were not exercised here.
- **`rename`/`unlink`/replace ops and files outside the granted tree** beyond the S6 negative control; very deep trees.
- **Cross-launch persistence.** Each run granted fresh via the panel; resolving a *saved* `.withSecurityScope` bookmark across app relaunches (Task 7's actual mechanism) was proven separately in 6.5 for the app, but not re-exercised end-to-end with child spawns here.
- **x86_64 slice / Rosetta.** arm64 only at runtime.

## Status

**DONE.** Question answered with a real, observed, Apple-Development-signed end-to-end run: direct children (`/bin/sh` and bundled Node) inherit the app's security-scoped grant for absolute-path writes throughout a user-selected folder (S0–S4 PASS), and a never-granted path is denied for app and child alike (S6 PASS-as-expected-fail). The MAS architecture does not need the XPC helper; Tasks 4/5/6 should be reverted for the MAS target in favor of `InProcessBackend` + an app-held per-site grant. The throwaway spike project at `/tmp/AppSpawnSpike/` is not committed.
