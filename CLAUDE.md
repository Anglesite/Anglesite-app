# Anglesite-app — Development Context

This is the **native macOS app** that hosts the Anglesite Claude plugin. The plugin lives in a sibling repo at `../anglesite`. Both repos are under the same `github.com/Anglesite/` parent directory.

## Two-repo coordination

| Repo | Role |
|---|---|
| `Anglesite/anglesite` | Claude plugin: skills, hooks, MCP server, docs |
| `Anglesite/Anglesite-app` *(this repo)* | macOS app: SwiftUI shell, website template, embedded Node, WKWebView preview, edit overlay |

The **website template** (Astro project skeleton, themes, scaffold script, pre-deploy check) lives in this repo at `Resources/Template/`. It is a committed, first-class app resource — not copied from the plugin at build time. `TemplateRuntime` resolves it from the app bundle (with a Settings override for development).

Cross-cutting work (e.g. extending the MCP server with `apply-edit` messages) lands as paired PRs:

1. Plugin PR adds the server-side support and ships in a tagged plugin release.
2. App PR consumes it and bumps the bundled-plugin pointer.

Paired PRs are only needed for MCP schema changes and skill additions — template changes are app-only.

When in doubt, the plugin is the source of truth for skills, hooks, and the MCP message schema. The app is a *host* — it does not own those. The app *does* own the template.

## Stack

- **Swift / SwiftUI** — app shell. Targets macOS 27+.
- **Plain SwiftUI + actors** for v0. No TCA, no third-party state libraries.
- **WKWebView** — live preview of the Astro dev server.
- **Embedded Node** — vendored at build time. Both targets re-sign it via a `scripts/resign-node.sh` post-build phase with the app's identity + hardened runtime: the MAS target uses `node-runtime.entitlements` (sandbox/inherit + JIT), the DevID target uses `node-runtime-devid.entitlements` (same minus the sandbox keys). The DevID re-sign + bundle-seal verification is done (#4 — `codesign --verify --deep --strict` passes); only the real Developer-ID-cert notarize run remains deferred (#1, gated on the signing cert + `TEAM_ID`).
- **MCP** — talks to the plugin's server over stdio (local subprocess) or HTTP/Streamable transport (for container-backed runtimes). `MCPClient` abstracts the transport behind an `MCPTransport` seam; `SiteRuntime` (protocol) abstracts the execution substrate so `PreviewModel` doesn't know whether a site runs in-process or in a container.

## Site identity — the `.anglesite` package

A site is a self-contained `.anglesite` **package** (#242) — a directory with the
`dev.anglesite.site` package UTI (`LSTypeIsPackage`). Layout:

- `Info.plist` — marker: format version + **stable site UUID** + display name + created date. Identity is the UUID (path-independent), so moving/renaming a package keeps its identity.
- `Source/` — the Astro project, a git repo. The externally-editable, clonable unit; `cd`/git/VS Code/CLI descend into it.
- `Config/` — app-owned per-site state (`settings.plist` via `SiteConfigStore`, `chat-history.jsonl`, caches). **Never** in git. `.site-config` stays in `Source/` (template/plugin-owned).

`AnglesitePackage` (AnglesiteCore) is the single source of truth for this layout. The app opens packages explicitly — Finder double-click / `onOpenURL`, **File ▸ Open Site…** (an `NSOpenPanel` filtering on the `dev.anglesite.site` UTI via `UTType.anglesiteSite`), **Open Recent** — and discovers them via a **recents registry** (`SiteStore`, `recents.json`), not by scanning a folder. `SiteStore.Site` carries `packageURL` + computed `sourceDirectory`/`configDirectory` (there is no `path`).

Operationally: **File ▸ Import** copies a plain Anglesite directory into a new package (migrating any legacy `.anglesite/` into `Config/`); **File ▸ Export** copies `Source/` back out. New sites scaffold into `Source/` (with `git init`); the dev server, deploy, and `pre-deploy-check` all run with cwd = `Source/`. On MAS, one security-scoped bookmark per package covers both `Source/` and `Config/`. `~/Sites/` is now just the default save location for new/imported packages — not a discovery root (there is no legacy `sites.json` migration, so Import is the upgrade path for pre-package sites).

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
├── Template/          Website template (themes, scaffold script, Astro source, pre-deploy check) — committed
├── node-runtime/      (gitignored) Vendored Node binary, populated by scripts/vendor-node.sh
├── plugin/            (gitignored) Plugin MCP server + skills, populated by scripts/copy-plugin.sh
│                      (template excluded — lives in Resources/Template/ instead)
├── Anglesite.help/    Apple Help Book (HTML pages; hiutil index built by scripts/build-help-index.sh)
└── *.entitlements     Per-target sandbox/signing entitlements (incl. node-runtime.entitlements for the MAS Node re-sign)
```

## Editing guidelines

- **No frameworks beyond Apple's** for v0 (Sparkle is the only third-party Swift dep, and only at v0.5).
- **Process spawning is centralized** in `AnglesiteCore/ProcessSupervisor` — never call `Process()` from a view.
- **Logs are sacred** — every spawned subprocess streams stdout+stderr into the debug pane. Do not silently `>/dev/null`.
- **The app cannot bypass plugin security hooks** — `pre-deploy-check.sh` runs before every deploy, and the app surfaces failures rather than allowing override.
- **The filesystem is the source of truth** — the app must never become the only way to edit a site. A site is now an `.anglesite` **package** (#242): Finder treats it as opaque (double-click opens it in Anglesite), but its `Source/` subdirectory is an ordinary git repo, so `cd`, `git`, VS Code, and the Claude Code CLI all descend into `Foo.anglesite/Source/` and keep working. App-owned per-site state lives beside it in `Foo.anglesite/Config/`, outside that repo. (Per #72 this still reframes to **Git** as the source of truth — the `Source/` repo, clonable anywhere, is the externally-editable copy — but only once the container runtimes (#66/#69) land and every site is a repo (#68). The package model is compatible with both states; don't finalize the filesystem→Git wording before that ships, or the doc describes an unshipped state.)

## Worktrees (default for feature/agent work)

Do feature work — and **all** dispatched-agent work — in a git worktree, never directly on the main checkout. Multiple agents run in parallel here, so the main tree must stay clean. Worktrees live under `.claude/worktrees/<name>/`.

- **Run `xcodegen generate` first** — `Anglesite.xcodeproj` is gitignored and regenerated from `project.yml`, so a fresh worktree has no project file until you generate it.
- **Set `ANGLESITE_PLUGIN_SRC`** — its default (`../anglesite`) resolves wrong from inside a worktree; point it at the real plugin checkout (`…/github.com/Anglesite/anglesite`) so `copy-plugin.sh` finds the plugin.
- **Dispatched subagents must `cd` to the worktree** — give them a hard `cd <worktree>` guard before any git op, or they run against the main checkout.

## Build

Toolchain: **Xcode 27+ / Swift 6.4** (required for SwiftUI 27's `@State` macro semantics — see [`docs/specs/2026-06-10-xcode27-state-macro-audit-notes.md`](docs/specs/2026-06-10-xcode27-state-macro-audit-notes.md)).

```sh
# Open the app project (not `xed .` — that opens Package.swift, which only
# has the library scheme `Anglesite-Package` and no runnable target).
open Anglesite.xcodeproj
# Anglesite.xcodeproj is gitignored and generated from project.yml — after a
# fresh clone or in a new worktree, run `xcodegen generate` first.
# ⌘B in Xcode, or:
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
# Sandboxed App Store target:
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build
```

Tests: `swift test --package-path .` (665 tests as of 2026-06-17 — 561 Swift Testing `@Test` + 104 XCTest — across `AnglesiteCoreTests` (403 `@Test` + 104 XCTest), `AnglesiteIntentsTests` (145 `@Test`), and `AnglesiteBridgeTests` (13 `@Test`)). Most suites are Swift Testing (#74); the only XCTest holdouts are 15 unit suites in `AnglesiteCoreTests` — `AnglesiteBridgeTests` and `AnglesiteIntentsTests` are fully Swift Testing. The MCP / apply-edit e2e tests (`AppliesEditEndToEndTests`, `MCPClientHTTPEndToEndTests`) need the sibling plugin checkout + node; when absent they **fail** rather than skip (they `throw` a `SkipReason` error, which Swift Testing — unlike XCTest's `XCTSkip` — records as an issue), so set `ANGLESITE_PLUGIN_PATH` to the plugin checkout to run them. If `swift build`/`swift test` seems to hang with no output, a stale SwiftPM process is likely holding the `.build` lock — check `pgrep -fl swift-test` and kill the orphan rather than assuming a bad test.

Note: `swift test` runs on CI's older runners even though `Package.swift` declares `.macOS("27.0")` — a SwiftPM CLI test binary tolerates a high deployment target as long as it doesn't call macOS-27-only symbols at runtime. **Hosted** app tests (`xcodebuild test` with `Anglesite.app` as the test host) do *not* work there: launching a macOS-27 `.app` is blocked on a macOS-15 runner by LaunchServices. So app-target logic that needs CI coverage (e.g. `DeployModel`'s token orchestration) is kept thin and pushed into a testable `AnglesiteCore` type (`TokenOnboarding`) rather than tested through a hosted app target.

## Plan

`gh issue list` is the source of truth for what to work on, with [`docs/build-plan.md`](docs/build-plan.md) for the phased roadmap. The inline issue numbers below are illustrative and may be stale (many are already closed) — confirm against gh before picking up work. Current phase: **Phase 10** — v2 polish (tracking: #34). Phases 0–9 are complete. Within Phase 10, the **Apple Help Book** has shipped and the **sandboxed Mac App Store build (Phase 10.1)** is most of the way there: the `AnglesiteMAS` target, the app-held per-site security-scoped grant (Task 7), the bundled-Node re-sign (Task N), routing all `Process()` through `ProcessSupervisor` (Task 8), and compiling chat/Sparkle/`gh` out of MAS (Tasks 9–10) are all done and build clean. **Remaining (Phase 10.1):** real-signed write-heavy MAS smoke (Task 11 — also confirms whether `cs.disable-library-validation` on the bundled Node is actually needed for sharp/native addons), the App Store release pipeline (Task 12), and closeout (Task 13). Still-open follow-ups: Sparkle manual key/appcast setup; app icon (#55 — `scripts/generate-app-icon.swift` renders the `</>` brand mark as a teal/blue squircle at all 10 macOS sizes; shipped and no longer a blank Xcode placeholder, but re-run with a professionally designed 1024px PNG if real artwork arrives); notarization for the DevID track — the embedded-Node re-sign is now wired on both targets (#4 done via `scripts/resign-node.sh` post-build phases), but the real Developer-ID signing + notarize/staple dry run (#1) and the notarized clean-Mac spawn smoke (#5) still need the signing cert + `TEAM_ID` (scripts ready: `scripts/notarize-dry-run.sh`). (The shared-output-path issue is fixed: the MAS target builds `AnglesiteMAS.app`, display name still "Anglesite".)

**Containerization epic (#59):** The `SiteRuntime` protocol (#65) and HTTP/Streamable MCP transport (#64) are landed and shipping. The Apple Containerization spike (#60 — MAS-incompatible, DevID-only) is done; the Cloudflare Sandbox throwaway spike (#61 — shared OCI image built) is still open. **Intended behavior:** Apple Containerization is the primary runtime (local, near-native perf, no network dependency); Cloudflare Sandbox is the automatic fallback on unsupported platforms or bundles (MAS, iOS, non-Apple-Silicon). Production runtimes (`LocalContainerSiteRuntime` #69, `RemoteSandboxSiteRuntime` #66) and the iOS thin client (#71) are open.

**macOS 27 / Siri AI:** the first platform wave has shipped (system-wide MCP, Spotlight App-Intents indexing, View Annotations, App Intents Testing, Foundation Models chat, SwiftUI 27 toolbars, the Xcode 27 migration audit). Ongoing work is tracked under the Siri AI phases (A–D, ~#132–135) and their sub-issues — check `gh issue list` for the live set.

**`.anglesite` package model (#242):** shipped — a site is a `.anglesite` package (see "Site identity" above). Design + phase plans: [`docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md`](docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md) and `docs/superpowers/plans/2026-06-19-anglesite-package-model-p{1..5}-*.md`. It dovetails with the still-open epics: the git-bootstrap (#68) and container runtimes (#66/#69) operate on the package's `Source/` repo, and `Config/` never enters a container. The first open follow-up is the `SiteConfigStore.displayName` override consumer (#266).
