# Anglesite-app — Development Context

This is the **native macOS app** that hosts the Anglesite Codex plugin. The plugin lives in a sibling repo at `../anglesite`. Both repos are under the same `github.com/Anglesite/` parent directory.

## Two-repo coordination

| Repo | Role |
|---|---|
| `Anglesite/anglesite` | Codex plugin: skills, hooks, MCP server, docs |
| `Anglesite/Anglesite-app` *(this repo)* | macOS app: SwiftUI shell, website template, WKWebView preview, edit overlay |

The **website template** (Astro project skeleton, themes, scaffold script, pre-deploy check) lives in this repo at `Resources/Template/`. It is a committed, first-class app resource — not copied from the plugin at build time. `TemplateRuntime` resolves it from the app bundle (with a Settings override for development).

Cross-cutting work (e.g. extending the MCP server with `apply-edit` messages) lands as paired PRs:

1. Plugin PR adds the server-side support and ships in a tagged plugin release.
2. App PR consumes it and bumps the bundled-plugin pointer.

Paired PRs are only needed for MCP schema changes and skill additions — template changes are app-only.

When in doubt, the plugin is the source of truth for skills, hooks, and the MCP message schema. The app is a *host* — it does not own those. The app *does* own the template.

> **Direction note:** the Claude Code / plugin-skill dependency is being retired under epic #459 (see "Plan" below). New feature journeys should land as deterministic Swift/TypeScript or Apple Intelligence paths, not new `claude --print` / markdown-skill paths.

## Stack

- **Swift / SwiftUI** — app shell. Targets macOS 27+.
- **Plain SwiftUI + actors** for v0. No TCA, no third-party state libraries.
- **WKWebView** — live preview of the Astro dev server.
- **No host-side Node runtime** — retired (#70). Dev-server, build, and deploy commands run inside a container runtime (local Apple Containerization or the remote Cloudflare sandbox) instead of a bundled host Node.
- **MCP** — talks to the plugin's server over stdio (local subprocess) or HTTP/Streamable transport (for container-backed runtimes). `MCPClient` abstracts the transport behind an `MCPTransport` seam; `SiteRuntime` (protocol) abstracts the execution substrate so `PreviewModel` doesn't know whether a site runs in-process or in a container.

## Site identity — the `.anglesite` package

A site is a self-contained `.anglesite` **package** (#242) — a directory with the
`io.dwk.anglesite.site` package UTI (`LSTypeIsPackage`). Layout:

- `Info.plist` — marker: format version + **stable site UUID** + display name + created date. Identity is the UUID (path-independent), so moving/renaming a package keeps its identity.
- `Source/` — the Astro project, a git repo. The externally-editable, clonable unit; `cd`/git/VS Code/CLI descend into it.
- `Config/` — app-owned per-site state (`settings.plist` via `SiteConfigStore`, `chat-history.jsonl`, caches). **Never** in git. `.site-config` stays in `Source/` (template/plugin-owned).

`AnglesitePackage` (AnglesiteSiteModel, re-exported by AnglesiteCore) is the single source of truth for this layout. The app opens packages explicitly — Finder double-click / `onOpenURL`, **File ▸ Open Site…** (an `NSOpenPanel` filtering on the `io.dwk.anglesite.site` UTI via `UTType.anglesiteSite`), **Open Recent** — and discovers them via a **recents registry** (`SiteStore`, `recents.json`), not by scanning a folder. `SiteStore.Site` carries `packageURL` + computed `sourceDirectory`/`configDirectory` (there is no `path`).

Operationally: **File ▸ Import** copies a plain Anglesite directory into a new package (migrating any legacy `.anglesite/` into `Config/`); **File ▸ Export** copies `Source/` back out. New sites scaffold into `Source/` (with `git init`); the dev server, deploy, and `pre-deploy-check` all run with cwd = `Source/`. On MAS, one security-scoped bookmark per package covers both `Source/` and `Config/`. `~/Sites/` is now just the default save location for new/imported packages — not a discovery root (there is no legacy `sites.json` migration, so Import is the upgrade path for pre-package sites).

## Build target

| Scheme | Bundle id | Distribution | Sandbox |
|---|---|---|---|
| `Anglesite` | `io.dwk.anglesite` | Mac App Store | App Sandbox |

`Anglesite` is the only app target. It sets `ANGLESITE_MAS` via `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, is sandboxed, holds a per-`SiteWindow` security-scoped bookmark grant, and links `AnglesiteContainer` for the local Apple Containerization runtime. Direct-download distribution is retired.

## Module layout

```
Sources/
├── AnglesiteApp/        SwiftUI views, app entry point, scenes, settings
├── AnglesiteCore/       Subprocess supervision, MCP client, edit pipeline, Keychain
├── AnglesiteSiteModel/  `.anglesite` site package model (AnglesitePackage, package layout)
├── AnglesiteIntents/    App Intents: Siri/Shortcuts/Spotlight entities and intents
├── AnglesiteContainer/  Apple Containerization local container runtime
├── AnglesiteIOS/        iOS WKWebView preview shell for the remote-only runtime path (#71)
└── AnglesiteBridge/     WKWebView script messages + JS overlay injection
JS/
└── edit-overlay/        TypeScript edit overlay compiled and bundled into app resources
Resources/
├── Template/            Website template (themes, scaffold script, Astro source, pre-deploy check) — committed
├── plugin/              (gitignored) Plugin MCP server + skills, populated by scripts/copy-plugin.sh
│                        (template excluded — lives in Resources/Template/ instead)
├── container-image/     (gitignored) Vendored arm64 OCI image, populated by scripts/vendor-container-image.sh
├── container-kernel/    (gitignored) Vendored Linux kernel binary, populated by scripts/vendor-container-kernel.sh
├── container-initfs/    (gitignored) Vendored vminit initfs OCI layout, populated by scripts/vendor-container-kernel.sh
├── Anglesite.help/      Apple Help Book (HTML pages; hiutil index built by scripts/build-help-index.sh)
└── *.entitlements       App sandbox/signing entitlements
```

## Editing guidelines

- **No frameworks beyond Apple's** unless explicitly approved.
- **Process spawning is centralized** in `AnglesiteCore/ProcessSupervisor` — never call `Process()` from a view.
- **Logs are sacred** — every spawned subprocess streams stdout+stderr into the debug pane. Do not silently `>/dev/null`.
- **The app cannot bypass plugin security hooks** — `pre-deploy-check.sh` runs before every deploy, and the app surfaces failures rather than allowing override.
- **Git is the source of truth** (#72) — the app must never become the only way to edit a site. A site's canonical, externally-editable copy is its `Source/` **git repo**, clonable anywhere. A site is an `.anglesite` **package** (#242): Finder treats it as opaque (double-click opens it in Anglesite), but `cd`, `git`, VS Code, and the Codex CLI all still descend into `Foo.anglesite/Source/` and keep working, and that repo can be cloned and edited outside the app entirely. App-owned per-site state lives beside it in `Foo.anglesite/Config/`, outside the repo (never in git). The app's own local working copy is not canonical: it lives **inside the site runtime/container** (#66/#69), hydrated from the repo when a site opens and pushed back to it — so any clone of the repo, not the app's working tree, is the unit everything else derives from. See [`docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md`](docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md) §8 (the #72 reconciliation) and the [containerization notes](docs/specs/2026-06-09-containerization-mas-subspike-notes.md).

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
```

Tests: `swift test --package-path .` runs the SwiftPM test targets (`AnglesiteSiteModelTests`, `AnglesiteCoreTests`, `AnglesiteBridgeTests`, and, on Swift 6.4+/Xcode 27, `AnglesiteIntentsTests`). `AnglesiteContainerLocalTests` is opt-in with `ANGLESITE_CONTAINER_TESTS=1`; its end-to-end cases also require `ANGLESITE_CONTAINER_E2E=1`. Most suites are Swift Testing (#74), with the remaining XCTest holdouts in `AnglesiteCoreTests` and `AnglesiteBridgeTests`. The MCP / apply-edit e2e tests (`AppliesEditEndToEndTests`, `MCPClientHTTPEndToEndTests`) need the sibling plugin checkout + node; they're gated with Swift Testing's `.enabled(if:)` trait, so they skip cleanly when the plugin is absent — set `ANGLESITE_PLUGIN_PATH` to the plugin checkout to make them run. If `swift build`/`swift test` seems to hang with no output, a stale SwiftPM process is likely holding the `.build` lock — check `pgrep -fl swift-test` and kill the orphan rather than assuming a bad test.

Note: `swift test` runs on CI's older runners even though `Package.swift` declares `.macOS("27.0")` — a SwiftPM CLI test binary tolerates a high deployment target as long as it doesn't call macOS-27-only symbols at runtime. **Hosted** app tests (`xcodebuild test` with `Anglesite.app` as the test host) do *not* work there: launching a macOS-27 `.app` is blocked on a macOS-15 runner by LaunchServices. So app-target logic that needs CI coverage (e.g. `DeployModel`'s token orchestration) is kept thin and pushed into a testable `AnglesiteCore` type (`TokenOnboarding`) rather than tested through a hosted app target.

## Plan

`gh issue list` is the source of truth for what to work on, with [`docs/build-plan.md`](docs/build-plan.md) for the phased roadmap. The inline issue numbers below are illustrative and may be stale (many are already closed) — confirm against gh before picking up work. Current phase: **Phase 10** — v2 polish (tracking: #34). Phases 0–9 are complete. Within Phase 10, the **Apple Help Book** has shipped and the app is now a single sandboxed Mac App Store target. Remaining release work is real-signed write-heavy smoke, the restricted virtualization entitlement/provisioning approval, and App Store submission.

**Containerization epic (#59):** The `SiteRuntime` protocol (#65) and HTTP/Streamable MCP transport (#64) are landed and shipping. Apple Containerization is the macOS runtime direction: `LocalContainerSiteRuntime` imports the app-bundled OCI layout, boots it with Apple's Containerization framework, and exposes preview/MCP over vsock proxies. Docker/buildx is only an image-build tool for producing that OCI root filesystem; the app does not run Docker. The active macOS image source is `Containers/anglesite-dev/`, vendored by `scripts/vendor-container-image.sh` into `Resources/container-image/`. The lowercase `container/` directory is the Cloudflare Sandbox / remote-runtime image pipeline for `RemoteSandboxSiteRuntime` and iOS work, not the app-bundled macOS image. Local-container selection is gated at runtime on the restricted virtualization entitlement and provisioned image/kernel/initfs resources.

**macOS 27 / Siri AI:** the platform wave has shipped and the Siri AI phases A–D (#132–135) are all closed (system-wide MCP, Spotlight App-Intents indexing, View Annotations, App Intents Testing, Foundation Models chat, SwiftUI 27 toolbars, the Xcode 27 migration audit). Follow-on intelligence work now lives under the Claude Code removal epic below.

**Claude Code removal epic (#459):** the active migration driving current feature work — retire the `claude --print` subprocess, `ClaudeAgent`, and the markdown skills, replacing them with deterministic Swift/TypeScript plus Apple Intelligence (on-device Foundation Models, escalating to Private Cloud Compute). **No external LLM APIs, ever.** Spec: [`docs/superpowers/specs/2026-06-20-claude-code-removal-roadmap-design.md`](docs/superpowers/specs/2026-06-20-claude-code-removal-roadmap-design.md). Work lands as vertical slices (each ends "tool before brain": deterministic tool → FM Tool + App Intent + GUI → delete that journey's `claude --print` path). Slices 1, 2, and 4 (#460, #461, #463) have landed; Slice 3 (#462, integrations wizard catalog) is in flight; Slices 5–7 (#464–466) are queued. Slice 7 deletes `ClaudeAgent` and converts the plugin repo — so don't extend the Claude-plugin path for new features without checking this epic first.

**`.anglesite` package model (#242):** shipped — a site is a `.anglesite` package (see "Site identity" above). Design + phase plans: [`docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md`](docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md) and `docs/superpowers/plans/2026-06-19-anglesite-package-model-p{1..5}-*.md`. It dovetails with the container epics: the git-bootstrap (#68, shipped) and the still-open container runtimes (#66/#69) operate on the package's `Source/` repo, and `Config/` never enters a container. The `SiteConfigStore.displayName` override consumer (#266) has since shipped.
