# Anglesite (Mac app)

A native macOS app that wraps the [Anglesite Claude plugin](https://github.com/Anglesite/anglesite) and gives non-technical site owners a click-to-edit experience for their website.

The app does not replace the plugin — it embeds it. Scaffolding, edits, deploys, and skills all flow through the same skills, hooks, and MCP server that Claude Code uses today; this app is a custom **host** for that machinery with native UI on top.

## Status

**Pre-release.** The v0 → v1 core is built (Phases 0–9): embedded Node runtime, plugin/site plumbing, supervised subprocesses, the WKWebView live preview with click-to-edit overlay routed through the plugin's MCP server, deploy via `wrangler` (with the plugin's mandatory pre-deploy scan), Keychain/`gh` credentials, the per-site chat panel, multi-window, the deploy-readiness health badge, image-drop optimization, and per-edit undo.

In progress (Phase 10, v2 polish):
- **Sandboxed Mac App Store build (Phase 10.1).** A second target, `AnglesiteMAS`, ships under the App Sandbox. It uses the same in-process subprocess path as the Developer ID build, holding a per-site security-scoped bookmark grant so the directly-spawned Node/Astro/wrangler children inherit folder access (no XPC helper — see the architecture pivot in [`docs/specs/2026-05-27-sandboxed-app-store-plan.md`](docs/specs/2026-05-27-sandboxed-app-store-plan.md)). The bundled Node is re-signed with hardened-runtime JIT/sandbox entitlements. Chat, Sparkle auto-update, and the `gh` Settings panel are compiled out of the MAS build (`#if !ANGLESITE_MAS`). *Not yet run end-to-end under real App Store signing (Task 11); the App Store submission pipeline is pending (Task 12).*
- **Apple Help Book** — shipped. 15 hand-authored HTML pages with `hiutil` search index, accessible via Help ▸ Anglesite Help.

Also landed since v1:
- **`SiteRuntime` protocol** (#65) — abstracts the execution substrate so `PreviewModel` is decoupled from how a site runs (in-process subprocess vs. local container vs. Cloudflare).
- **HTTP/Streamable MCP transport** (#64) — `MCPClient` can connect over HTTP in addition to stdio, enabling container-backed runtimes.
- **Containerization spikes** — Apple Containerization (#60, DevID-only; MAS-incompatible) and Cloudflare Sandbox (#61, shared OCI image) are complete. Production container runtimes (#66, #69) and the iOS thin client (#71) are open.
- **Xcode 27 migration** (#108) — macOS 27+ deployment target, `@State` macro audit, Swift 6.4 toolchain. Both schemes build clean; 662 tests pass.
- **macOS 27 platform features** (open) — system-wide MCP (#101), Spotlight/App Intents (#102), native chat on Foundation Models (#105), and more.

See [`docs/build-plan.md`](docs/build-plan.md) for the full phased status.

## Documentation

- [Build plan](docs/build-plan.md) — phased implementation roadmap
- [High-level design](../anglesite/docs/dev/mac-app-design.md) — companion design doc in the plugin repo

## Requirements

- macOS 27+
- Xcode 27+ (Swift 6.4; required for the SwiftUI 27 `@State` macro semantics audited in [`docs/specs/2026-06-10-xcode27-state-macro-audit-notes.md`](docs/specs/2026-06-10-xcode27-state-macro-audit-notes.md))
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the `.xcodeproj` is generated from [`project.yml`](project.yml)
- A bundled Node.js runtime is shipped with the app — users do not need Node installed.

## Building

```sh
# Clone alongside the plugin repo
git clone https://github.com/Anglesite/Anglesite-app.git
cd Anglesite-app

# Vendor the bundled Node runtime (version pinned in scripts/node-version.txt)
scripts/vendor-node.sh

# Generate the Xcode project
xcodegen generate

# (Recommended) Enable git hooks that auto-regenerate the .xcodeproj after
# `git pull` / branch switches / rebases — keeps Xcode in sync with project.yml
# and Sources/ without manual `xcodegen generate` calls.
git config core.hooksPath scripts/git-hooks

# (Optional one-time verification) Confirm project.yml hasn't drifted from the
# source tree — regenerates the .xcodeproj and checks every app target compiles all
# of Sources/AnglesiteApp. CI runs this too, so it's not a required setup step.
scripts/check-xcodeproj-sync.sh

# Build via CLI (ad-hoc signed; no Apple account required)
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build

# The sandboxed Mac App Store target builds the same way:
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build

# Or open in Xcode (note: `open Anglesite.xcodeproj`, NOT `xed .`)
open Anglesite.xcodeproj
```

There are two app targets, both ad-hoc-signed in Debug so they build without an Apple account:

| Scheme | Bundle id | Distribution | Sandbox |
|---|---|---|---|
| `Anglesite` | `dev.anglesite.app` | Developer ID (notarized, Sparkle auto-update) | off |
| `AnglesiteMAS` | `dev.anglesite.app.mas` | Mac App Store | on (App Sandbox) |

> **Don't `xed .`** — this repo contains both a `Package.swift` and an `Anglesite.xcodeproj`. `xed .` opens the package, whose scheme picker only shows `Anglesite-Package` (libraries only, no runnable target). Open the `.xcodeproj` explicitly; the scheme picker should then show `Anglesite`, `AnglesiteMAS`, `AnglesiteCore`, and `AnglesiteBridge`, and ⌘R should run the app.

The Debug configuration uses ad-hoc signing so contributors can build and run locally without any Apple Developer enrollment. Notarized Release builds require a paid Apple Developer account — see [`docs/xcode-setup.md`](docs/xcode-setup.md) for the full distribution path.

## Relationship to the plugin repo

This repo expects to live next to `Anglesite/anglesite` on disk (both checked out under the same parent directory). At build time the Xcode project copies the plugin into `Resources/plugin/`. For local plugin development, point **Settings → Advanced → Plugin path** at your working copy of the plugin.

## License

ISC. See [LICENSE](LICENSE).
