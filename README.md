# Anglesite (Mac app)

A native macOS app that wraps the [Anglesite Claude plugin](https://github.com/Anglesite/anglesite) and gives non-technical site owners a click-to-edit experience for their website.

The app does not replace the plugin — it embeds it. Scaffolding, edits, deploys, and skills all flow through the same skills, hooks, and MCP server that Claude Code uses today; this app is a custom **host** for that machinery with native UI on top.

## Status

**Pre-release.** Phase 1 (embedded Node runtime) in progress — launching the app runs a vendored-Node smoke test (`1+1` → `2`) to prove the embedded runtime spawns. See [`docs/build-plan.md`](docs/build-plan.md).

## Documentation

- [Build plan](docs/build-plan.md) — phased implementation roadmap
- [High-level design](../anglesite/docs/dev/mac-app-design.md) — companion design doc in the plugin repo

## Requirements

- macOS 14+
- Xcode 26+ (current as of this writing)
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

# Build via CLI (ad-hoc signed; no Apple account required)
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build

# Or open in Xcode (note: `open Anglesite.xcodeproj`, NOT `xed .`)
open Anglesite.xcodeproj
```

> **Don't `xed .`** — this repo contains both a `Package.swift` and an `Anglesite.xcodeproj`. `xed .` opens the package, whose scheme picker only shows `Anglesite-Package` (libraries only, no runnable target). Open the `.xcodeproj` explicitly; the scheme picker should then show `Anglesite`, `AnglesiteCore`, and `AnglesiteBridge`, and ⌘R should run the app.

The Debug configuration uses ad-hoc signing so contributors can build and run locally without any Apple Developer enrollment. Notarized Release builds require a paid Apple Developer account — see [`docs/xcode-setup.md`](docs/xcode-setup.md) for the full distribution path.

## Relationship to the plugin repo

This repo expects to live next to `Anglesite/anglesite` on disk (both checked out under the same parent directory). At build time the Xcode project copies the plugin into `Resources/plugin/`. For local plugin development, point **Settings → Advanced → Plugin path** at your working copy of the plugin.

## License

ISC. See [LICENSE](LICENSE).
