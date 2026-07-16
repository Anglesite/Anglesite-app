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

## Platform UX standards

Every user-facing design and implementation must follow the standard for its target platform. Treat the applicable release acceptance checklist as part of feature definition and QA—not as optional polish—and do not flatten platform behavior into a lowest-common-denominator cross-platform UI.

- **macOS:** [`docs/mac-assed-app-spec.md`](docs/mac-assed-app-spec.md). Current app work must preserve Mac conventions, including menus, keyboard commands, windows, files, Undo/Redo, VoiceOver, and system integration.
- **iOS and iPadOS:** [`docs/ios-ipados-assed-app-spec.md`](docs/ios-ipados-assed-app-spec.md). Mobile work must distinguish the focused iPhone experience from iPad's adaptive multitasking, keyboard, pointer, Apple Pencil, and drag-and-drop context.
- **Android:** [`docs/android-assed-app-spec.md`](docs/android-assed-app-spec.md). Android work must distinguish touch-first phone use from adaptive tablet, foldable, keyboard, pointer, and windowed contexts while preserving Android Back, intents, lifecycle, and accessibility behavior.
- **Windows:** [`docs/windows-assed-app-spec.md`](docs/windows-assed-app-spec.md). Future Windows work must use Windows-native commands, shell integration, accessibility, DPI/multi-monitor behavior, and packaging.
- **Linux (Ubuntu GNOME baseline):** [`docs/linux-assed-app-spec.md`](docs/linux-assed-app-spec.md). Future Linux work must follow Ubuntu GNOME patterns while respecting freedesktop.org interoperability, Wayland, portals, XDG data locations, accessibility, and the shipped package format.

When shared-core constraints conflict with a platform convention, keep the shared behavior deterministic and introduce a thin platform-shell adaptation rather than weakening the native experience on every platform. Document any intentional convention departure in the feature design and verify that it is clearer, accessible, reversible, and justified for the task.

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

Note: `swift test` runs on CI's older runners even though `Package.swift` declares `.macOS("27.0")` — a SwiftPM CLI test binary tolerates a high deployment target as long as it doesn't call macOS-27-only symbols at runtime. **Hosted** app tests (`xcodebuild test` with `Anglesite.app` as the test host) do *not* work there: launching a macOS-27 `.app` is blocked on an older-macOS runner by LaunchServices. (The Swift lanes run on macos-26 — bumped from macos-15, whose Swift 6.2.x OS concurrency runtime carried a task-allocator bug that crashed whole `swift test` runs with "freed pointer was not the last allocation", see PR #644/#646.) So app-target logic that needs CI coverage (e.g. `DeployModel`'s token orchestration) is kept thin and pushed into a testable `AnglesiteCore` type (`TokenOnboarding`) rather than tested through a hosted app target.

## Plan

`gh issue list` is the source of truth for what to work on, with [`docs/build-plan.md`](docs/build-plan.md) for the phased roadmap. The inline issue numbers below are illustrative and may be stale (many are already closed) — confirm against gh before picking up work. Current phase: **Phase 10** — v2 polish (tracking: #34). Phases 0–9 are complete.

**Issue-in-flight signaling.** Multiple agents work this repo concurrently (see "Worktrees" above), so before starting work on a tracked issue, check it isn't already claimed and mark that you're taking it: `gh issue list --label status:in-progress` to check, then `gh issue edit <n> --add-label status:in-progress` to claim it. Remove the label when a PR opens for it (`gh issue edit <n> --remove-label status:in-progress`) — the PR itself is the up-to-date signal from then on. If you find an issue already fixed/merged before you could start (as happens — two agents can pick the same issue in the same window), don't silently redo the work: check for an existing PR/commit first, and if one already landed, close the issue referencing it rather than duplicating the fix.

Within Phase 10, the **Apple Help Book** has shipped and the app is now a single sandboxed Mac App Store target. Remaining release work is real-signed write-heavy smoke, a `scripts/release.sh --validate-only` signing check, and App Store submission. (The `com.apple.security.virtualization` entitlement is **unrestricted** — no Apple approval or provisioning-profile grant is needed; ad-hoc Debug builds boot containers. Verified 2026-07-07, see the subspike notes addendum.)

**Containerization epic (#59):** The `SiteRuntime` protocol (#65) and HTTP/Streamable MCP transport (#64) are landed and shipping. Apple Containerization is the macOS runtime direction: `LocalContainerSiteRuntime` imports the app-bundled OCI layout, boots it with Apple's Containerization framework, and exposes preview/MCP over vsock proxies. The image is built with Apple's `container` CLI (`scripts/vendor-container-image.sh`); building the app needs no Docker. The active macOS image source is `Containers/anglesite-dev/`, vendored by `scripts/vendor-container-image.sh` into `Resources/container-image/`. The lowercase `container/` directory is the Cloudflare Sandbox / remote-runtime image pipeline for `RemoteSandboxSiteRuntime` and iOS work (`scripts/build-container-image.sh`, the only remaining Docker/buildx consumer), not the app-bundled macOS image. Local-container selection is gated at runtime on the virtualization entitlement and provisioned image/kernel/initfs resources.

**macOS 27 / Siri AI:** the platform wave has shipped and the Siri AI phases A–D (#132–135) are all closed (system-wide MCP, Spotlight App-Intents indexing, View Annotations, App Intents Testing, Foundation Models chat, SwiftUI 27 toolbars, the Xcode 27 migration audit). Follow-on intelligence work now lives under the Claude Code removal epic below.

**Claude Code removal epic (#459):** the active migration driving current feature work — retire the `claude --print` subprocess, `ClaudeAgent`, and the markdown skills, replacing them with deterministic Swift/TypeScript plus Apple Intelligence (on-device Foundation Models, escalating to Private Cloud Compute). **LLM policy (revised 2026-07-08):** platform-native on-device AI is the default; external LLMs are supported **only as an explicit Settings opt-in** (user-configured endpoint + key, which also covers self-hosted servers like Ollama — supports less capable machines), and features that require a frontier-class model are **clearly labeled** BBEdit-style, never a silent degraded cloud call. See [`docs/superpowers/specs/2026-07-08-cross-platform-swift-port-design.md`](docs/superpowers/specs/2026-07-08-cross-platform-swift-port-design.md) §8. Spec: [`docs/superpowers/specs/2026-06-20-claude-code-removal-roadmap-design.md`](docs/superpowers/specs/2026-06-20-claude-code-removal-roadmap-design.md). Work lands as vertical slices (each ends "tool before brain": deterministic tool → FM Tool + App Intent + GUI → delete that journey's `claude --print` path). Slices 1–4 and 6 (#460–463, #465) have landed — Slice 3 closed 2026-07-09 with the Keystatic-backed integration catalog (its runtime inbox-capture follow-up is #587, blocked on `@dwk/workers`); Slice 6 (2026-07-10) shipped content help on FM (copy-edit / social-media / repurpose over the shared content-help kernel: `BrandVoiceGuidance` + interview, `SiteContentChunker`, `ContentAssistantFactory` tier seam — spec `docs/superpowers/specs/2026-07-10-slice6-content-help-fm-design.md`); slices 5 and 7 (#464, #466) remain queued. Slice 7 deletes `ClaudeAgent` and converts the plugin repo — so don't extend the Claude-plugin path for new features without checking this epic first.

**`.anglesite` package model (#242):** shipped — a site is a `.anglesite` package (see "Site identity" above). Design + phase plans: [`docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md`](docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md) and `docs/superpowers/plans/2026-06-19-anglesite-package-model-p{1..5}-*.md`. It dovetails with the container epics: the git-bootstrap (#68, shipped) and the container runtimes — #69 (shipped) and the deferred remote runtime (#66) — operate on the package's `Source/` repo, and `Config/` never enters a container. The `SiteConfigStore.displayName` override consumer (#266) has since shipped.

**Other active tracks (status 2026-07-10):**

- **Component Editor epic (#496):** Swift-native WYSIWYG for Astro components (spec: `docs/superpowers/specs/2026-07-05-component-editor-design.md`). Slice 1 (read-only editor, plugin v1.3.0), slice 2 (Styles panel write ops, plugin v1.4.0), and slice 3 (structure ops + palette, plugin v1.5.0) have landed; next is props/zone code editors (#494). Each slice ships a paired plugin release + `MIN_PLUGIN_VERSION` bump.
- **Personal Publishing OS pivot (#334):** V-1 (typed content objects + feeds, #335) shipped, including the content-type registry, mf2/JSON-LD projection, and per-type editors. V-2–V-5 (Webmention/POSSE, inbound interactions, ActivityPub + reader, communities) are **gated on a conformant `@dwk/workers` release**. Runtime inbox capture (#587) shipped independently of that gate — it doesn't depend on any `@dwk/*` package (Webmention/Micropub's shapes don't fit a public anonymous submission endpoint) — landing a bespoke `/inbox` Worker route + `INBOX_KV` staging + app-side git commit-back (`InboxSubmissionSync`). No Settings UI provisions it yet; `SiteSettings.inboxCaptureAccountID`/`inboxCaptureKVNamespaceID` are the storage slots a future wizard fills in.
- **Menu bar / toolbar completeness (#518):** swept 2026-07-08/09 — Save/menus/customizable toolbar, macOS conventions (proxy icon, Dock menu, ShareLink, launcher drops, Settings tabs), preview navigation, dev-server controls, navigator content commands, Print, notifications, ⌘Z, String Catalog scaffolding all landed. Remaining: Edit ▸ Find + Format menu (#517), toolbar search (#520), manual GUI verification of the navigator commands (#586).
- **Cross-platform Swift port (#571):** Anglesite v2 on Windows & Linux (spec: `docs/superpowers/specs/2026-07-08-cross-platform-swift-port-design.md`). Phased P1–P5 (#566–570), Linux first; P1 (Linux CI leg + portability seams) is the entry point. This epic is where the revised LLM policy's `ExternalLLMBackend` lands (P5).
- **UTM-VM dev/test rig (#589):** validate `SiteRuntime` across macOS/Windows/Linux guests on the Mac Studio. Phase-1 (#601) landed in full — guest side (`LANControlClient` + factory/Settings wiring, PR #604) and the host-side `anglesite-lan-host` CLI (`Sources/AnglesiteLANHost`, one site per instance, ports 4321/4399) that runs a site's Astro dev server + MCP sidecar bound to the LAN interface.
- **Site Graph Explorer (#308, shipped)** follow-ups: mini-map (#613) and AI node explanations (#614 — on-device FM first, per the LLM policy); the older free-form "explain my site" request (#314) should build on #614's grounding rather than a new path.
