# Anglesite Mac App — Build Plan

**Status:** Draft
**Companion design doc:** [`anglesite/docs/dev/mac-app-design.md`](../../anglesite/docs/dev/mac-app-design.md)
**Audience:** Contributors building the native macOS app in this repo.

This plan turns the high-level design into a concrete, phased implementation roadmap. Phases map to the v0 → v2 milestones in §12 of the design doc.

## Phase 0 — Repo + Xcode bootstrap

**Goal:** A buildable, signable, empty SwiftUI app committed to its own git repo.

1. `git init` in `Anglesite-app/`. Add `.gitignore` (Xcode, SwiftPM, DerivedData, `.DS_Store`, `node-runtime/`).
2. Create Xcode project: macOS App, SwiftUI lifecycle, Swift, deployment target macOS 14 (matches WKWebView/SwiftUI APIs needed).
   - Bundle id: `dev.anglesite.app` (or `io.dwk.anglesite` — decide before signing).
   - Capabilities: **off** sandbox for v0 (per §10), Hardened Runtime **on**, allow JIT + unsigned executable memory (Node needs both), allow DYLD env vars.
3. Add a top-level `README.md`, `LICENSE` (ISC to match plugin), `CLAUDE.md` (a short one — points back to `anglesite/CLAUDE.md` for plugin context).
4. Add module structure inside the app target:
   - `AnglesiteApp/` — SwiftUI views + app entry
   - `AnglesiteCore/` — subprocess supervision, MCP client, edit pipeline
   - `AnglesiteBridge/` — WKWebView script messages + JS injection
5. Set up CI (GitHub Actions) for `xcodebuild` build + unit tests on `macos-15`.
6. **Sign + notarize** dry run with a placeholder build to confirm Developer ID flow before any real code lands.

## Phase 1 — Embedded Node runtime

This is the riskiest piece, so do it first.

1. ✅ Decide on `node` vs `bun` (design doc §13 leaves it open). Recommend `node` for v0 — Astro is officially supported, notarization is well-trodden, fewer surprises.
2. ✅ Vendor a Node.js macOS universal binary into `Resources/node-runtime/` via a build script (download + verify signature + lipo arm64/x86_64).
3. Re-sign the embedded `node` with the app's Developer ID (notarization requires every Mach-O to be signed by the same team). *(Deferred — Debug builds use ad-hoc signing; Release re-sign lands when notarization is wired up.)*
4. ✅ Smoke test: spawn `node -e "console.log(1+1)"` from `NSTask`/`Process`, confirm it works in a notarized build. *(Ad-hoc-signed Debug confirmed; notarized confirmation deferred with step 3.)*
5. Bundle a primed `node_modules/` cache strategy: ship a tarball of plugin + template `node_modules`, extract on first launch into `~/Library/Application Support/Anglesite/cache/`. Sites `npm install --prefer-offline` against this cache.

## Phase 2 — Plugin + site project plumbing

1. ✅ Bundle a known-good copy of the Anglesite plugin in `Resources/plugin/` (copied from `../anglesite` at build time via the `Bundle Anglesite plugin` pre-build script in `project.yml`). Stamp the copy with the source commit for diagnostics.
2. ✅ `SiteStore` (Swift actor): manages `~/Sites/<name>/` directories. Discovers existing projects (look for `anglesite.config.json`), persists the list in `~/Library/Application Support/Anglesite/sites.json`.
3. ✅ `ProjectValidator`: confirms a directory is an Anglesite project (`anglesite.config.json`, `astro.config.ts`, `keystatic.config.ts`). Returns which sentinels are missing so the UI can show partial-scaffold remediation.
4. ✅ **Settings → Advanced → Plugin path** override (per §7) wired up early — lets the plugin author point the app at `../anglesite` while iterating. `Sites root` override added alongside for development/testing.

## Phase 3 — Subprocess supervisor

1. ✅ `ProcessSupervisor` actor: spawns, restarts on crash (exponential backoff), streams stdout/stderr (via `LogCenter` + libdispatch `readabilityHandler`), handles graceful shutdown. Cancellable `waitForExit(_:)` so task groups can unwind without waiting for the real process exit. `shutdownAll(_:)` drains every supervised child — wired to `AppDelegate.applicationShouldTerminate` so nothing outlives the app. `onRespawn` callback lets a wrapper re-establish session state after a supervised restart. App-wide instance is `ProcessSupervisor.shared`.
2. ✅ `AstroDevServer`: wraps `astro dev` with a `parseReadyURL` regex (ANSI-stripped) and races URL match / unexpected exit / timeout in a single `withThrowingTaskGroup`. Once the `Local …` line is spotted it is *probed over HTTP* (Astro logs the URL a beat before it serves) and only returned on a real response — `ReadinessProbe` is injectable. Restart-on-crash is on by default (`maxAttempts: 3, baseBackoff: 0.5`); a watcher republishes `readyURL` after a restart picks a new port.
3. ✅ `MCPClient`: spawns the server with `attachStdin: true`, speaks JSON-RPC 2.0 over stdio (NDJSON via LogCenter). v0 surface: `initialize`, `tools/list`, `tools/call`. Includes a `JSONValue` codec for typed but `Sendable` request/response shapes. Restart-on-crash is on by default; on respawn the client fails in-flight requests (`MCPError.reconnecting`) and re-runs the `initialize` handshake against the fresh process. *(The cross-repo `messages.mjs` schema-mirror CI check from issue #13 is deferred to Phase 5 — Phase 3's surface is the standard MCP framing, with nothing app-specific to mirror yet.)*
4. ✅ **Debug pane** behind `View → Show Debug Pane` (`⌥⌘D`): live tail of all subprocess stdout/stderr from `LogCenter.shared`, with source/stream filter chips, free-text search, pause (freezes the view; the buffer keeps filling), auto-scroll, copy / save-to-file, and ring-buffer replay of pre-open history. Hidden in Release builds unless the user opts in (Settings → Advanced → Diagnostics) or holds ⌥ at launch; always shown in Debug builds. Filter/export logic lives in `LogCenter` extensions with unit coverage.

## Phase 4 — WKWebView + edit overlay (v0 core)

1. `PreviewView` (SwiftUI + `NSViewRepresentable<WKWebView>`): loads `http://localhost:<port>` from the dev server.
2. `WKScriptMessageHandler` for namespace `anglesite`: receives edit messages from injected JS.
3. **JS edit overlay**: write a small TS module in `Anglesite-app/JS/edit-overlay.ts` that compiles to a single bundle. Loads on every page via WKWebView userContentController. Behavior:
   - Hover → outline + edit handle
   - Click text node → `contentEditable=true`
   - Drop image on `<img>` → upload via script message
   - On blur/debounce → post `{type, path, selector, op, value}` to native
4. **Critical decision:** the overlay should reuse `anglesite/server/selector.mjs` logic. Either compile that module to JS for the overlay, or have the overlay send raw element metadata and let the MCP server compute the selector. Recommend the latter — keeps one source of truth.
5. Native side routes the message to MCP via `anglesite:apply-edit` (new message type, see Phase 5).

## Phase 5 — Source patcher (in the plugin repo, not the app)

This work lands in `anglesite/server/` — the app repo just calls it.

1. Add `server/patcher.mjs` with three resolvers in priority order: `.mdoc` → Keystatic schema → `.astro` static text. Each resolver returns `{file, range, replacement}` or refuses with a reason.
2. Extend `server/messages.mjs` with `apply-edit`, `edit-applied`, `edit-failed`.
3. Wire `server/index.mjs` to dispatch the new message types.
4. Implement the **hidden git branch** undo: every successful patch commits to `anglesite/edits` branch. Add `server/edit-history.mjs`.
5. Tests in `anglesite/test/patcher.test.js` covering each resolver + ambiguous-match refusal.
6. **Bounce-to-Claude path** is deferred to v0.5 — for v0, ambiguous edits surface a "Can't edit this directly — try chat (coming soon)" sheet.

## Phase 6 — Deploy button (v0 finishing)

1. `DeployCommand`: shells out to `wrangler deploy` from the site directory. Cloudflare token from Keychain (Phase 7) or env.
2. **Pre-deploy hook honored**: invoke `scripts/pre-deploy-check.sh` from the bundled plugin. On failure, surface the structured output as a sheet with remediation steps; do not allow override.
3. Output streamed to a transient drawer; success shows the deployed URL with a "Copy/Open" button.

## Phase 7 — Keychain + secrets

1. `KeychainStore` for the Cloudflare API token. First-launch deploy prompts; subsequent deploys read silently.
2. `gh` device-code flow stays in `gh` — the app just spawns it and surfaces the URL/code in a sheet.

## Phase 8 — v0.5 chat panel

1. `ChatView` (SwiftUI): markdown rendering, tool-call cards, native permission sheets.
2. `ClaudeAgent`: spawns `claude --plugin-dir <bundled-plugin> --output-format stream-json` in the site directory. Parse stream-json, render incrementally.
3. Skill buttons (Deploy, Backup, Check, Import) inject `/anglesite:<skill>` into chat.
4. Sticky notes from the existing toolbar arrive as chat messages — already an MCP message type, just route to chat instead of a separate UI.
5. Sparkle integration + signed appcast on `anglesite.dev`.

## Phase 9 — v1 multi-site + drag-drop images

1. Sidebar supports N sites; switching tears down + spins up dev server.
2. Health badge polls `/anglesite:check` periodically.
3. Image drop → call `optimize-images` skill via MCP → write to `public/` → patch `src=`.
4. Undo affordance per edit in the chat panel, backed by the hidden git branch.

## Phase 10 — v2 polish

Per design doc §12: sandboxed App Store build (helper-tool architecture for Node), Quick Look, Spotlight, Settings polish.

---

## Cross-cutting decisions to lock in early

- **Single-window with tabs** (per §11 open question) — recommend deciding now to avoid a v1 rewrite.
- **Chat history per-site** in `.anglesite/chat-history.jsonl`, included in the GitHub backup.
- **Swift architecture: plain SwiftUI + actors for supervisors.** No TCA for v0 — keeps the maintainer pool wide.
- **Two repos, coordinated:** changes spanning `anglesite/server/patcher.mjs` and the app land as paired PRs. Document this in `Anglesite-app/CLAUDE.md`.

## Suggested first PR to land

A single PR containing Phases 0 + 1 + a "hello world" that spawns embedded Node and prints `2` in the UI. That's the smallest slice that proves the riskiest assumption (notarized embedded Node works) and gives a foundation everything else builds on.
