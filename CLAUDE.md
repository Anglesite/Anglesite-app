# Anglesite-app — Development Context

This is the **native macOS app** that hosts the Anglesite Claude plugin. The plugin lives in a sibling repo at `../anglesite`. Both repos are under the same `github.com/Anglesite/` parent directory.

## Two-repo coordination

| Repo | Role |
|---|---|
| `Anglesite/anglesite` | Claude plugin: skills, hooks, MCP server, template, docs |
| `Anglesite/Anglesite-app` *(this repo)* | macOS app: SwiftUI shell, embedded Node, WKWebView preview, edit overlay |

Cross-cutting work (e.g. extending the MCP server with `apply-edit` messages) lands as paired PRs:

1. Plugin PR adds the server-side support and ships in a tagged plugin release.
2. App PR consumes it and bumps the bundled-plugin pointer.

When in doubt, the plugin is the source of truth for skills, hooks, and the MCP message schema. The app is a *host* — it does not own those.

## Stack

- **Swift / SwiftUI** — app shell. Targets macOS 27+.
- **Plain SwiftUI + actors** for v0. No TCA, no third-party state libraries.
- **WKWebView** — live preview of the Astro dev server.
- **Embedded Node** — vendored at build time. Both targets re-sign it via a `scripts/resign-node.sh` post-build phase with the app's identity + hardened runtime: the MAS target uses `node-runtime.entitlements` (sandbox/inherit + JIT), the DevID target uses `node-runtime-devid.entitlements` (same minus the sandbox keys). The DevID re-sign + bundle-seal verification is done (#4 — `codesign --verify --deep --strict` passes); only the real Developer-ID-cert notarize run remains deferred (#1, gated on the signing cert + `TEAM_ID`).
- **MCP** — talks to the plugin's server over stdio.

## Two build targets

| Scheme | Bundle id | Distribution | Sandbox |
|---|---|---|---|
| `Anglesite` (DevID) | `dev.anglesite.app` | Developer ID + Sparkle auto-update | off |
| `AnglesiteMAS` | `dev.anglesite.app.mas` | Mac App Store | App Sandbox |

Both share the `Sources/AnglesiteApp` code and the same `InProcessBackend` spawn path. MAS-only differences are gated with `#if ANGLESITE_MAS` (set via `SWIFT_ACTIVE_COMPILATION_CONDITIONS` on the MAS *app target* only — **not** on the `AnglesiteCore`/`AnglesiteBridge` SPM package, so a guard in those packages is a no-op). The MAS build is sandboxed and holds a per-`SiteWindow` security-scoped bookmark grant so directly-spawned children inherit folder access; chat, Sparkle, and the `gh` Settings panel are compiled out of it.

## Module layout

```
Sources/
├── AnglesiteApp/      SwiftUI views, app entry point, scenes, settings
├── AnglesiteCore/     Subprocess supervision, MCP client, edit pipeline, Keychain
└── AnglesiteBridge/   WKWebView script messages + JS overlay injection
JS/
└── edit-overlay/      TypeScript edit overlay compiled and bundled into app resources
Resources/
├── node-runtime/      (gitignored) Vendored Node binary, populated by scripts/vendor-node.sh
├── plugin/            (gitignored) Copy of ../anglesite, populated by scripts/copy-plugin.sh
│                      (runs as a pre-build phase; respects $ANGLESITE_PLUGIN_SRC override)
├── Anglesite.help/    Apple Help Book (HTML pages; hiutil index built by scripts/build-help-index.sh)
└── *.entitlements     Per-target sandbox/signing entitlements (incl. node-runtime.entitlements for the MAS Node re-sign)
```

## Editing guidelines

- **No frameworks beyond Apple's** for v0 (Sparkle is the only third-party Swift dep, and only at v0.5).
- **Process spawning is centralized** in `AnglesiteCore/ProcessSupervisor` — never call `Process()` from a view.
- **Logs are sacred** — every spawned subprocess streams stdout+stderr into the debug pane. Do not silently `>/dev/null`.
- **The app cannot bypass plugin security hooks** — `pre-deploy-check.sh` runs before every deploy, and the app surfaces failures rather than allowing override.
- **The filesystem is the source of truth** — the app must never become the only way to edit a site. Owners can open `~/Sites/<name>/` in Finder, VS Code, or Claude Code CLI and continue working.

## Build

```sh
# Open the app project (not `xed .` — that opens Package.swift, which only
# has the library scheme `Anglesite-Package` and no runnable target).
open Anglesite.xcodeproj
# ⌘B in Xcode, or:
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
# Sandboxed App Store target:
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build
```

Tests: `swift test --package-path .` (208 `AnglesiteCoreTests` unit tests plus the `AnglesiteBridgeTests` apply-edit e2e, which `XCTSkip`s when the sibling plugin checkout / node aren't present). If `swift build`/`swift test` seems to hang with no output, a stale SwiftPM process is likely holding the `.build` lock — check `pgrep -fl swift-test` and kill the orphan rather than assuming a bad test.

## Plan

See [`docs/build-plan.md`](docs/build-plan.md) for the phased roadmap. Current phase: **Phase 10** — v2 polish. Phases 0–9 are complete. Within Phase 10, the **Apple Help Book** has shipped and the **sandboxed Mac App Store build (Phase 10.1)** is most of the way there: the `AnglesiteMAS` target, the app-held per-site security-scoped grant (Task 7), the bundled-Node re-sign (Task N), routing all `Process()` through `ProcessSupervisor` (Task 8), and compiling chat/Sparkle/`gh` out of MAS (Tasks 9–10) are all done and build clean. **Remaining (Phase 10.1):** real-signed write-heavy MAS smoke (Task 11 — also confirms whether `cs.disable-library-validation` on the bundled Node is actually needed for sharp/native addons), the App Store release pipeline (Task 12), and closeout (Task 13). Still-open follow-ups: Sparkle manual key/appcast setup; **placeholder** app icon (#55 — `scripts/generate-app-icon.swift` draws a teal/blue "A" squircle at all 10 mac sizes; re-run with a 1024px PNG to drop in real artwork); notarization for the DevID track — the embedded-Node re-sign is now wired on both targets (#4 done via `scripts/resign-node.sh` post-build phases), but the real Developer-ID signing + notarize/staple dry run (#1) and the notarized clean-Mac spawn smoke (#5) still need the signing cert + `TEAM_ID` (scripts ready: `scripts/notarize-dry-run.sh`). (The shared-output-path issue is fixed: the MAS target builds `AnglesiteMAS.app`, display name still "Anglesite".)
