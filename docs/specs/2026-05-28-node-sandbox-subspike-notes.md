# Phase 10.1 — Node-in-Sandbox Sub-Spike Notes (vendored Node.js inside a sandboxed XPC service)

**Date:** 2026-05-28
**Follow-up to:** `docs/specs/2026-05-27-sandboxed-app-store-spike-notes.md` (Task 0), which explicitly did NOT test the vendored Node binary.
**Source plan:** `docs/specs/2026-05-27-sandboxed-app-store-plan.md` (precondition for Tasks 5/11)

## The question

Can a sandboxed XPC service spawn the **vendored Node.js binary** that Anglesite-app bundles, run a real Node workload, and get stdout/stderr/exit-code back? Node — not git — is what the preview pipeline (`node .../astro dev`) and the MCP server actually run, so it needs its own confirmation; Task 0 only proved `/bin/ls` and a direct-path `git` spawn.

## Verdict

**PASS.** Under ad-hoc signing, a sandboxed XPC helper spawned the vendored Node binary and ran all four escalating workloads with exit code 0: `--version`, V8 init (`process.versions`), a localhost HTTP bind, and a file read. This held for **both** signing variants tested (original Node-Foundation signature *and* an ad-hoc re-sign). No dyld, library-validation, or code-signing failure was observed. One caveat (MAS Distribution-profile library validation across Team IDs) is untested here and flagged below.

## Environment

```
$ sw_vers
ProductName:    macOS
ProductVersion: 26.5
BuildVersion:   25F71

$ xcodebuild -version
Xcode 26.5
Build version 17F42

$ security find-identity -v -p codesigning
     0 valid identities found        # no certs — ad-hoc (CODE_SIGN_IDENTITY = -), same as Task 0
```

### The Node binary

Source: the repo's already-vendored runtime, `Resources/node-runtime/bin/node` (populated by `scripts/vendor-node.sh`, version pinned in `scripts/node-version.txt` = **24.15.0**). Copied verbatim into the spike's app and helper bundles.

```
$ file Resources/node-runtime/bin/node
Mach-O universal binary with 2 architectures:
  [x86_64:Mach-O 64-bit executable x86_64] [arm64]

$ codesign -dv Resources/node-runtime/bin/node
Identifier=node
Format=Mach-O universal (x86_64 arm64)
CodeDirectory v=20500 size=930000 flags=0x10000(runtime) hashes=29052+7 location=embedded
Signature size=8986
Timestamp=Apr 14, 2026 at 21:45:42
TeamIdentifier=HX7739G8FX          # <-- Node Foundation's Apple Team ID
Runtime Version=15.0.0
```

**Critical signing fact:** the vendored Node is NOT ad-hoc. It ships **signed by the Node Foundation (TeamIdentifier=HX7739G8FX)** with the **hardened-runtime flag set (0x10000)**. This is precisely the configuration most likely to trip library validation when launched as a child of an ad-hoc/no-team sandboxed parent. (The Task 0 spike noted Node "ships without xcrun-shimming, so it has a better chance" — that turned out to be the easy part; the foreign Team ID was the real risk, and it was tested directly.)

### Ad-hoc signing note

All builds used `CODE_SIGN_IDENTITY = -`. Xcode auto-disabled hardened runtime on the *app* and *helper* (ad-hoc). The app bundle itself signs as `flags=0x2(adhoc), TeamIdentifier=not set`. So in every test the **parent** (helper) is ad-hoc/no-team; only the Node **child** varied (see variants).

## What was built

Throwaway project at `/tmp/NodeSpike/` (NOT committed; will be deleted). Modeled on the Task 0 `/tmp/SandboxSpike/` structure:

- `NodeSpike.app` — minimal SwiftUI app. Entitlements: `app-sandbox`, `files.user-selected.read-write`, `network.client`, `network.server`, `cs.allow-jit`, `cs.allow-unsigned-executable-memory`. Auto-runs the probe on launch (no GUI click needed), writes the report into its sandbox-container `Documents/report.txt`.
- `ProbeHelper.xpc` — embedded XPC service. Entitlements exactly as the spec required for the real `AnglesiteHelper`:
  ```
  app-sandbox, inherit, network.server, network.client,
  files.user-selected.read-write, cs.allow-jit, cs.allow-unsigned-executable-memory
  ```
  Exposes one `runNode` method that spawns Node and runs the 4 tests via `Process()`, capturing exit/stdout/stderr per test.
- Built with xcodegen → xcodebuild; ad-hoc signed. App and helper land in separate sandbox containers (`io.dwk.nodespike.app`, `io.dwk.nodespike.probe`) as expected.

Codesign-verified helper entitlements (post-build) — all present:
```
app-sandbox: true   inherit: true   network.server: true   network.client: true
files.user-selected.read-write: true   cs.allow-jit: true
cs.allow-unsigned-executable-memory: true   get-task-allow: true (Xcode Debug inject)
```

### Two signing variants of the Node child were tested

1. **Re-signed ad-hoc** (`codesign -f -s - node` at build time) → `flags=0x2(adhoc), TeamIdentifier=not set`. This is the MAS "we re-sign Node with our own identity" scenario.
2. **Original signature left intact** → `flags=0x10000(runtime), TeamIdentifier=HX7739G8FX`. This is the "ship Node as-downloaded" scenario and the riskier of the two for library validation.

## A path gotcha worth recording (not a Node finding)

First attempt ran the app from `/private/tmp/.../NodeSpike.app`. The sandboxed helper got `NSCocoaErrorDomain Code=4 "The file 'node' doesn't exist"` for a path that plainly existed — the sandbox does not grant a helper read access to an app bundle living under `/tmp`. Also, the helper cannot write into the *app's* container (cross-container). Fixes that made the probe representative of the real app:

- Install/run the app from `~/Applications/` (normal bundle location; sandbox grants bundle read access).
- Resolve Node from the **helper's own** `Contents/Resources/node-runtime/bin/node` and use the **helper's own** container for HOME + cwd.

Neither is a Node limitation; both are how the real AnglesiteHelper is already designed (Node and helper co-bundled, helper writes within granted scope). Recorded so Task 5 doesn't rediscover it.

## The four tests — verbatim output

Identical results for BOTH signing variants. Output below is the run with the **original Node-Foundation signature** (the riskier variant); the ad-hoc-re-signed run was byte-identical except port number and probe-file timestamp.

Helper preamble (foreign-signed variant):
```
[helper] using nodePath=.../ProbeHelper.xpc/Contents/Resources/node-runtime/bin/node
[helper] node exists: true
[helper] node executable: true
```

### TEST 1 — `node --version` (does the binary launch in the sandbox?)
```
exit=0
stdout: v24.15.0
stderr: <empty>
```

### TEST 2 — `node -e "console.log(JSON.stringify(process.versions))"` (V8 init; where cs.allow-jit matters)
```
exit=0
stdout: {"node":"24.15.0","acorn":"8.16.0","ada":"3.4.4","amaro":"1.1.8","ares":"1.34.6","brotli":"1.2.0","cldr":"48.0","icu":"78.2","llhttp":"9.3.1","merve":"1.2.2","modules":"137","napi":"10","nbytes":"0.1.3","ncrypto":"0.0.1","nghttp2":"1.68.0","openssl":"3.5.5","simdjson":"4.5.0","simdutf":"6.4.0","sqlite":"3.51.3","tz":"2026a","undici":"7.24.4","unicode":"17.0","uv":"1.51.0","uvwasi":"0.0.23","v8":"13.6.233.17-node.48","zlib":"1.3.1-e00f703","zstd":"1.5.7"}
stderr: <empty>
```

### TEST 3 — Node binds a localhost port (where network.server matters; this is exactly what `astro dev` does)
Script: `const s=require('http').createServer((q,r)=>r.end('ok')); s.listen(0,'127.0.0.1',()=>{console.log('listening',s.address().port); s.close(()=>process.exit(0))}); ...`
```
exit=0
stdout: listening 60145
stderr: <empty>
```
(ad-hoc-re-signed variant: `listening 60144`.)

### TEST 4 — Node reads a file the helper wrote into its granted directory
```
[helper] wrote probe file: .../io.dwk.nodespike.probe/Data/Documents/nodespike-probe.txt
exit=0
stdout: FILE_CONTENTS=hello-from-helper-1779975864
stderr: <empty>
```
File access flows from the helper's granted scope to the Node child. (Note: this used the helper's *own container*, which is always granted, rather than a user-selected dir; user-selected → helper access via `inherit` was already proven for child processes in Task 0, so it was not re-litigated here.)

## Findings

### Finding 1 (the load-bearing answer): the vendored Node launches and runs fully inside the sandboxed XPC helper
`Process()` against the vendored Node binary works from inside a sandboxed XPC service. The binary launches (Test 1), V8 initializes with the full version table (Test 2), and the process exits cleanly with captured stdout. `cs.allow-jit` + `cs.allow-unsigned-executable-memory` on the helper are sufficient for V8 — no extra entitlement or `com.apple.security.cs.disable-library-validation` was needed in this ad-hoc configuration.

### Finding 2 (the foreign-Team-ID risk did NOT materialize under ad-hoc): no library-validation or dyld failure
The original Node binary carries `TeamIdentifier=HX7739G8FX` and the hardened-runtime flag, while its sandboxed parent is ad-hoc/no-team. This is the classic library-validation mismatch. **It launched anyway** — exit 0, no `code signature invalid`, no `library load disallowed by system policy`, no dyld error, and no kernel `Sandbox: ... deny` lines in `log show`. Node's only dylib dependencies are `/System/...` frameworks and `/usr/lib/*` (CoreFoundation, Security, libc++, libSystem) — all system libraries, none from the bundle — so there is nothing for library validation to reject at the dylib level, and the executable-launch path accepted the foreign-team child. **Re-signing Node ad-hoc was NOT required to make it run here.**

### Finding 3 (network.server confirmed): Node can bind localhost inside the sandbox
Test 3 bound an ephemeral port on 127.0.0.1 and reported it. This is the exact operation the Astro dev server performs. `com.apple.security.network.server` on the helper is the entitlement that enables it.

### Finding 4 (no code-signing / dyld errors of any kind)
Across both variants and all four tests: zero code-signing errors, zero dyld errors, zero sandbox-deny log lines. The only error encountered in the whole spike was the self-inflicted `/tmp` bundle-path issue (see "path gotcha"), which is not a Node or signing problem.

## PASS / FAIL / PARTIAL verdict

**PASS** for "can a sandboxed XPC helper run the vendored Node" under the spike's ad-hoc, development-signed conditions — which are the same conditions Task 0 ran under and the same the current Anglesite-app Debug config uses.

It is **not** a blanket PASS for the shipping Mac App Store binary, because the spike could not exercise a real MAS **Distribution provisioning profile** (no certs on this machine). See the caveat in implications.

## Implications for the build plan

- **Tasks 5 (AnglesiteHelper) and 11 (MAS smoke fixture) are unblocked on the core question.** Spawning vendored Node from the sandboxed helper works; the helper's spec'd entitlement set (`inherit` + `network.server`/`network.client` + `cs.allow-jit` + `cs.allow-unsigned-executable-memory` + `files.user-selected.read-write`) is sufficient. No new entitlement was needed for V8 or for port binding. Co-bundle Node with the helper (or ensure the helper can read the app bundle) and run the app from a normal install location, not `/tmp`.

- **Re-signing Node is NOT a hard prerequisite to make it *launch* — but it is still strongly recommended before MAS submission, for a different reason.** This ad-hoc spike proves launch works with the foreign Team ID, so the deferred Developer-ID re-sign item (#1/#4) does **not** need to be pulled forward merely to get Node running. HOWEVER: (a) a notarized/MAS build runs under a real Team ID with library validation actually enforced by the system policy (not the ad-hoc bypass), and Apple's App Store review rejects bundled executables that aren't signed with the submitter's Team ID; and (b) the hardened-runtime flag on the original binary can interact with the Distribution profile. So plan to re-sign the vendored Node with the app's own identity (`codesign -f -s <identity> --options runtime node`) as part of the MAS packaging step — confirmed harmless here (ad-hoc re-sign ran identically), and almost certainly required for actual App Store acceptance. Treat "re-sign Node with the app's Team ID" as a **MAS packaging task (near Task 11/12)**, not a launch-blocker for Task 5.

- **`cs.allow-jit` suffices; nothing heavier was needed.** V8 initialized with `cs.allow-jit` + `cs.allow-unsigned-executable-memory` on the helper. We did **not** need `com.apple.security.cs.disable-library-validation`. Keep the helper entitlements as spec'd; do not add disable-library-validation unless a real Distribution-profile build later proves it necessary for the foreign-team Node (re-signing Node to the app's own team is the cleaner fix and avoids that entitlement entirely).

## What was NOT tested

- **Real MAS Distribution provisioning profile / proper Apple signing.** No certs on this machine; everything was ad-hoc. The single most important untested case is whether the foreign-Team-ID Node still launches when library validation is enforced for real (non-ad-hoc) — this is exactly why re-signing Node to the app's own Team ID is recommended before submission. Re-run this with a real cert during Task 11/12.
- **A real `astro dev` / MCP-server workload.** Tests used `node --version`, `node -e` snippets, and a bare `http` server. The actual preview pipeline loads npm modules from the bundled `lib/node_modules`, spawns child processes, watches files, and serves over a long-lived port. Long-running process supervision, file-watching (FSEvents/kqueue) under sandbox, and module resolution from the bundle were NOT exercised. Recommend a follow-up that runs the real Anglesite template's `astro dev` from the helper and confirms the WKWebView can reach the port.
- **x86_64 slice.** This machine is arm64; only the arm64 slice was exercised at runtime (the binary is universal and both slices are present, but Rosetta launch of the x64 slice inside the sandbox was not tested).
- **macOS 14 and 15.** This machine is macOS 26.5 only, same deferral as Task 0.
- **The npm/npx/corepack symlinks and `lib/` tree.** Only the `node` binary itself was copied into the spike bundles; the surrounding runtime tree (`lib/node_modules`, the symlinked launchers) was omitted because the four tests don't need it. A real workload does — verify the full vendored tree survives bundling + (re-)signing.
- **Stdin streaming / long-lived stdout drain.** The probe read stdout to EOF on short-lived processes. The MCP stdio transport and the dev-server log stream are long-lived; pipe-draining under sandbox for a persistent child was not tested.

## Status

**DONE.** Core question answered PASS. The vendored Node runs inside a sandboxed XPC helper, V8 initializes, it binds localhost, and exit/stdout/stderr propagate — for both the original Node-Foundation signature and an ad-hoc re-sign. One deferred verification (real MAS Distribution-profile signing + a real `astro dev` workload) should happen at Task 11/12, but nothing here blocks Task 5.
