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

- **Swift / SwiftUI** — app shell. Targets macOS 14+.
- **Plain SwiftUI + actors** for v0. No TCA, no third-party state libraries.
- **WKWebView** — live preview of the Astro dev server.
- **Embedded Node** — vendored at build time, re-signed with Developer ID.
- **MCP** — talks to the plugin's server over stdio.

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
└── plugin/            (gitignored) Copy of ../anglesite, populated by scripts/copy-plugin.sh
                       (runs as a pre-build phase; respects $ANGLESITE_PLUGIN_SRC override)
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
```

## Plan

See [`docs/build-plan.md`](docs/build-plan.md) for the phased roadmap. Current phase: **Phase 9** — multi-window architecture has landed (#54, one window per site keyed by `SiteStore.Site.id`); remaining v1 work is the health badge polling `/anglesite:check`, image-drop → `optimize-images`, and per-edit undo. Phases 0–8 are otherwise complete with two outstanding asterisks: opt-in primed npm cache size budget (#6) and Sparkle manual key/appcast setup. Deferred Release-track: Developer ID re-sign of embedded Node + notarization (#1/#4).
