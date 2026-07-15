# Contributing to Anglesite (Mac app)

Thanks for your interest in contributing! This repo is the native macOS app that hosts the [Anglesite plugin](https://github.com/Anglesite/anglesite). It's pre-release and moving fast, so a quick read of this page will save you time.

## Before you start

- **Issues are the source of truth.** Check [`gh issue list`](https://github.com/Anglesite/Anglesite-app/issues) and [`docs/build-plan.md`](docs/build-plan.md) for what's planned and in flight.
- **Claim your issue.** Multiple contributors (and agents) work this repo concurrently. Before starting on a tracked issue, check it isn't already claimed (`gh issue list --label status:in-progress`), then add the `status:in-progress` label. Remove the label once your PR is open — the PR is the signal from then on.
- **Discuss big changes first.** For anything beyond a bug fix or small improvement, open an issue before writing code. In particular, new features should not add `claude --print` / markdown-skill paths — that dependency is being retired under epic [#459](https://github.com/Anglesite/Anglesite-app/issues/459).

For architecture, module layout, and project direction, read [`AGENTS.md`](AGENTS.md) — it's the canonical development-context document (mirrored as `CLAUDE.md` for Claude Code users).

## Development setup

Prerequisites and full build instructions live in the [README](README.md#requirements). The short version:

```sh
git clone https://github.com/Anglesite/Anglesite-app.git
cd Anglesite-app

# One-shot environment check/bootstrap: verifies prerequisites, generates the
# Xcode project, and enables the git hooks that keep it regenerated.
scripts/setup-dev-env.sh

# Build (ad-hoc signed — no Apple account required)
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Key things to know:

- **macOS 27+ and Xcode 27+ (Swift 6.4)** are required for the app itself. The `.xcodeproj` is gitignored and generated from [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen) — never edit or commit the project file; edit `project.yml`.
- **Open `Anglesite.xcodeproj`, not `xed .`** — the latter opens `Package.swift`, which has no runnable target.
- **Commit String Catalog updates.** App builds automatically extract SwiftUI and `String(localized:)` literals into `Sources/AnglesiteApp/Localizable.xcstrings` because `SWIFT_EMIT_LOC_STRINGS` is enabled. If you add, remove, or rename user-visible text, build the app target, review the generated `.xcstrings` diff, and include it in the same commit. Do not blindly restore the catalog when it appears after a build. If extraction looks incomplete or unexpectedly large, run a clean build (`xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug clean build`) and review the stabilized result before committing it.
- **Linux contributors welcome.** The portable SwiftPM targets build and test on Linux (Swift 6.3+, no Xcode or Node needed) — see [Developing on Linux](README.md#developing-on-linux). The cross-platform port ([#571](https://github.com/Anglesite/Anglesite-app/issues/571)) is an active track.
- **Plugin sibling checkout (optional).** Some end-to-end tests expect the plugin repo checked out next to this one (`../anglesite`); they skip cleanly when it's absent.

## Testing

Run the relevant suites before opening a PR:

```sh
# Swift package tests (AnglesiteSiteModel, AnglesiteCore, AnglesiteBridge, AnglesiteIntents)
swift test --package-path .

# App target builds
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build

# JS edit overlay (from JS/edit-overlay/, Node 22+)
npm run lint && npm run typecheck && npm test
```

Notes:

- Container runtime tests are opt-in: `ANGLESITE_CONTAINER_TESTS=1` (plus `ANGLESITE_CONTAINER_E2E=1` for end-to-end cases).
- MCP/apply-edit e2e tests run only when `ANGLESITE_PLUGIN_PATH` points at a plugin checkout; otherwise they skip.
- If you touch `Resources/Template/`, run `swift test` too — some Swift tests couple to the template markup.
- CI runs the JS overlay checks, Linux portable-target builds, macOS `swift test` (including ThreadSanitizer lanes), an `Anglesite.xcodeproj` ↔ `project.yml` sync check, and an AppIntents schema check. All must pass.

## Code guidelines

- **Swift/SwiftUI with Apple frameworks only** — plain SwiftUI + actors, no TCA or third-party state libraries. New dependencies need explicit approval in an issue first.
- **Process spawning is centralized** in `AnglesiteCore/ProcessSupervisor` — never call `Process()` from a view.
- **Logs are sacred** — every spawned subprocess streams stdout+stderr to the debug pane. Don't silently discard output.
- **Git is the source of truth for sites** — the app must never become the only way to edit a site. A site's `Source/` repo stays clonable and editable outside the app.
- **The app cannot bypass plugin security hooks** — `pre-deploy-check.sh` runs before every deploy; surface failures, don't add overrides.
- **JS/TypeScript** (edit overlay) uses ES modules, vanilla APIs, and the existing oxlint/tsc/vitest toolchain.

## Commits and pull requests

- **Conventional commits** — `feat(scope): …`, `fix(scope): …`, `ci: …`, etc. Reference the issue number in the subject when there is one (see `git log` for examples).
- **Fill out the [PR template](.github/PULL_REQUEST_TEMPLATE.md)**, including the paired-PR check and test plan.
- **Paired PRs.** Changes to the MCP message schema or plugin skills need a paired PR in [`Anglesite/anglesite`](https://github.com/Anglesite/anglesite): the plugin PR ships first in a tagged release, then the app PR consumes it. Template changes (`Resources/Template/`) are app-only. See `AGENTS.md` ▸ "Two-repo coordination".
- Keep PRs focused; opportunistic cleanup near the code you're touching is fine, drive-by refactors of unrelated code are not.

## License

By contributing, you agree that your contributions are licensed under the [ISC License](LICENSE) that covers this project.
