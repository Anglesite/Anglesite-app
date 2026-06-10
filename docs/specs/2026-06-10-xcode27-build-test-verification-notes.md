# Xcode 27 build/test verification notes

Date: 2026-06-10
Scope: issue #108 — the build-test half (`@State`-macro audit is in [`2026-06-10-xcode27-state-macro-audit-notes.md`](2026-06-10-xcode27-state-macro-audit-notes.md))
Toolchain: Xcode 27.0 (27A5194q), Swift 6.4 (swiftlang-6.4.0.20.104 clang-2100.3.20.102)
Host: macOS 27.0 (26A5353q), Apple silicon

## What this PR changes

- `Resources/Info.plist`, `Resources/AnglesiteMAS-Info.plist`: bump `LSMinimumSystemVersion` from `14.0` to `27.0`. This was the only Xcode-27-specific warning in either scheme's build:
  ```
  warning: LSMinimumSystemVersion of '14.0' is less than the value of MACOSX_DEPLOYMENT_TARGET '27.0'
    - setting to '27.0'. (in target 'Anglesite'/'AnglesiteMAS' …)
  ```
  Xcode auto-bumped the runtime key at build time, but the static plist drift was real — `project.yml` set `MACOSX_DEPLOYMENT_TARGET: "27.0"` in `c2de05f build(macos): require macOS 27+` without updating the plists.

## Setup

`Anglesite.xcodeproj/` is gitignored and regenerated from `project.yml` via XcodeGen. The optional `scripts/git-hooks/regenerate-xcodeproj.sh` post-checkout/post-merge/post-rewrite hook keeps it current, but it has to be opted into per-clone (`git config core.hooksPath scripts/git-hooks`). A checkout without the hooks enabled (or a manual `xcodegen generate` after `c2de05f`) builds against a stale `MACOSX_DEPLOYMENT_TARGET = 14.0` and fails with:

```
error: compiling for macOS 14.0, but module 'AnglesiteCore' has a minimum deployment target of macOS 27.0
```

(`AnglesiteCore` is built by SwiftPM and pinned to macOS 27 in `Package.swift`; the app target inherits the stale 14 from the pbxproj.)

Sequence on a fresh checkout:
```sh
git config core.hooksPath scripts/git-hooks   # one-time
xcodegen generate                              # one-time, or after any project.yml change
scripts/vendor-node.sh
```

## Build results

Both schemes succeed cleanly on Xcode 27 after the regen. Sequence on this run (with the plist fix applied):

| Scheme | Configuration | Result |
|---|---|---|
| `Anglesite` | Debug, clean build | ✅ BUILD SUCCEEDED |
| `AnglesiteMAS` | Debug, clean build | ✅ BUILD SUCCEEDED |

### Timing

Wall-clock from the clean-build run (`time xcodebuild ... clean build` for each scheme followed by `time swift test --package-path .`, all sequential):

| Phase | Wall time |
|---|---|
| `Anglesite` Debug `clean build` + `AnglesiteMAS` Debug `clean build`, combined | ~26 s |
| `swift test --package-path .` | ~22 s |
| **Total** | **~48 s** |

The combined-build figure is faster than two full from-scratch builds because Xcode reuses module artifacts across schemes inside the same DerivedData directory — both schemes link the same `AnglesiteCore`/`AnglesiteBridge`/`Sparkle` products. Wiping DerivedData entirely would roughly double the build phase.

Per-phase split between the two schemes isn't separately captured here — they live in the same xcodebuild log (`/tmp/xcode27-verification-v2.log` on the verification machine) but bash's `time` keyword output didn't survive the subshell redirect. Acceptable for this baseline; rerun with `/usr/bin/time -p` if a per-scheme number is wanted later.

### Warnings

After the plist fix:

| Source | Count | Verdict |
|---|---|---|
| `LSMinimumSystemVersion` mismatch | 0 (was 2 before this PR) | fixed |
| `appintentsmetadataprocessor: Metadata extraction skipped, no AppIntents.framework dependency found` | 2 | benign; the app doesn't use AppIntents, the tool just announces it ran |
| Swift / SwiftUI source warnings | 0 | the strict-concurrency cleanup from `ebf584f build(swift6): step 1 — strict concurrency on` is still clean under Xcode 27 |

No deprecation notices were emitted. `ViewBuilder` → `ContentBuilder` (called out in issue #108 as a possible diagnostic surface) didn't surface anything in this codebase.

## Test results

`swift test --package-path .` — Xcode 27 / Swift 6.4 / sequential (no `--parallel`), `ANGLESITE_PLUGIN_PATH` not set (test falls back to `../anglesite` sibling).

| Bundle | Framework | Outcome |
|---|---|---|
| `AnglesiteCoreTests` (XCTest portion) | XCTest | ✅ all suites pass |
| `AnglesiteCoreTests` (Swift Testing portion) | Swift Testing | ⚠️ 124/125 pass — 1 e2e failure (see below) |
| `AnglesiteBridgeTests` | Swift Testing | ⚠️ binary exits with signal 13 (SIGPIPE) during e2e |

### Failures (pre-existing, environment-sensitive)

Both failures are MCP-server-spawn end-to-end tests. They're not introduced by Xcode 27 and aren't observed in CI — CI cannot see them because **CI uses Xcode 16, not Xcode 27**, and runs `swift test -c debug --parallel` with `ANGLESITE_PLUGIN_PATH` set to a freshly `npm ci`'d plugin checkout. See [CI gap](#ci-gap) below.

1. `MCPClientHTTPEndToEndTests."HTTP end-to-end: connect, list tools, call list_annotations"` (`Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift:14`)
   ```
   recorded an issue at MCPClientHTTPEndToEndTests.swift:14:6: Caught error: .sessionLost
   failed after 20.187 seconds with 1 issue
   ```
   Test polls `MCPClient.connect(httpEndpoint:)` for 20s while the spawned `node server/index.mjs` (HTTP mode) comes up; throws `.sessionLost` on poll timeout. Local reproduction depends on plugin `node_modules` state and ambient node version. Filed under "pre-existing flake" not "Xcode 27 regression."

2. `AnglesiteBridgeTests` — process exits with SIGPIPE mid-output, around `AppliesEditEndToEndTests."Apply edit end to end mutates the file on disk"` (`Tests/AnglesiteBridgeTests/AppliesEditEndToEndTests.swift:45`). The swift-testing binary itself dies; output is truncated mid-line. Same likely root cause as #1 (MCP server lifecycle in the e2e harness on local).

These are worth a dedicated investigation but don't gate the Xcode 27 toolchain bump.

## CI gap

`.github/workflows/ci.yml` currently does:

```yaml
- uses: actions/checkout@v4

- name: Checkout sibling Anglesite plugin
  uses: actions/checkout@v4
  with:
    repository: Anglesite/anglesite
    path: anglesite-plugin

- name: Set up Node (for the bundled plugin's MCP server)
  uses: actions/setup-node@v4
  with:
    node-version: '22'

- name: Install plugin dependencies
  working-directory: anglesite-plugin
  run: npm ci --no-audit --no-fund

- name: Select Xcode
  run: sudo xcode-select -s /Applications/Xcode_16.app

- name: Build (debug)
  run: swift build -c debug

- name: Test
  env:
    ANGLESITE_PLUGIN_PATH: ${{ github.workspace }}/anglesite-plugin
  run: swift test -c debug --parallel

- name: Build (release)
  run: swift build -c release
```

So:
- CI uses **Xcode 16**, not Xcode 27. Nothing in CI exercises the Xcode 27 / Swift 6.4 toolchain that local dev now requires.
- CI uses `swift build`/`swift test` against `Package.swift`, never `xcodebuild` against `Anglesite.xcodeproj`. The xcodeproj-only failure modes (stale `MACOSX_DEPLOYMENT_TARGET`, the plist `LSMinimumSystemVersion` warning fixed by this PR) are invisible to CI.
- CI *does* check out the sibling `Anglesite/anglesite` plugin and `npm ci`s it, and sets `ANGLESITE_PLUGIN_PATH` so the MCP e2e tests run with a fresh plugin checkout. So the two local flakes documented above are not "tests CI skips" — they're tests CI runs under Xcode 16 + parallel + a clean plugin tree, and the flake on local could just as plausibly be an environmental difference in plugin state or node version as a real bug.

Bumping CI to Xcode 27 is a follow-up — it likely needs `macos-15` → `macos-26` or whatever runner image carries Xcode 27 — but is outside this PR's scope. Filed as a #108 follow-up item.

## Follow-ups

- Bump CI runner / `xcode-select` to Xcode 27 once a runner image ships it (separate PR).
- Investigate the MCP e2e flakes on local — `.sessionLost` after 20s suggests either the plugin's HTTP server start-up has regressed, or the test's poll budget is environment-sensitive. Likely a paired-PR concern with the plugin repo.
- Run the test suite with `--parallel` to mirror CI; the local sequential run is slower but more deterministic, and useful as a baseline.
