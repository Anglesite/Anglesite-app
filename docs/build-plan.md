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
5. 🟡 Primed npm cache: `scripts/vendor-npm-cache.sh` (opt-in prebuild phase — `ANGLESITE_BUILD_NPM_CACHE=1`) installs the bundled plugin/template deps into a shared npm cache, tarballs it to `Resources/npm-cache/cache.tar` + a `version.txt` stamp. `AnglesiteCore/NodeModulesCache` extracts it on launch into `~/Library/Application Support/Anglesite/npm-cache/` (re-extracts only on a version bump) and exposes `npm install --prefer-offline --cache <path>` flags. *Remaining:* measure the tarball size before turning the prebuild phase on by default (>100MB meaningfully bloats the DMG); wire the cache flags into the site-creation flow once the app owns site creation. Tracked in #6.

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

1. ✅ `PreviewView` (`NSViewRepresentable<WKWebView>`, AnglesiteApp): reloads `http://localhost:<port>` whenever the URL changes (incl. when a supervised dev-server restart rebinds a new port — surfaced via `AstroDevServer.onReadyURLChange`). The testable core is `PreviewSession` (actor, AnglesiteCore): `start(siteID:siteDirectory:)` resolves how to run `astro dev` for a site (`node_modules/.bin/astro` via the vendored Node, or `.failed("dependencies not installed — run npm install")`), drives an `AstroDevServer`, and exposes `State ∈ {idle, starting, ready(url), failed(msg)}` plus an `observe()` change stream. `PreviewModel` (`@Observable`, AnglesiteApp) mirrors that state; `ContentView` is now a sidebar of discovered sites + a main pane that shows the live preview for the selected site (placeholder/error states otherwise) — per-site *windows* are still Phase 9. `WebViewBridge.localDevConfiguration()` (no disk cache in Debug) + `applyLocalDevDefaults` (`isInspectable` in Debug, so ⌥⌘I devtools work); `Info.plist` gained `NSAllowsLocalNetworking` for the plain-http localhost load. *Note:* end-to-end "preview a real site" needs the site's `node_modules` (i.e. `npm install` having run — see #6); until then the preview pane surfaces the "dependencies not installed" state and the tests use a `/bin/sh` fixture dev server.
2. ✅ `WKScriptMessageHandler` for the `anglesite` namespace (#16). The JS → native channel lives in `AnglesiteBridge`: `EditMessage.decode(from:)` strictly validates `{id, type, path, selector, op, value}` at the boundary (only `type == "anglesite:apply-edit"` is accepted; unknown types fail decode); `EditRouter` is the seam (`LoggingEditRouter` is the wired default — logs to the Debug pane and replies `"Phase 5 lands the server side"`; `MCPApplyEditRouter` is the Phase-5-ready scaffold that calls `MCPClient.callTool(name: "anglesite:apply-edit", arguments: …)` and maps the result). `AnglesiteScriptHandler` (`WKScriptMessageHandler`) decodes, routes, and replies via `evaluateJavaScript("window.anglesite?._handleReply?.(<EditReply>)")` on the originating WKWebView; the decode → route → reply construction is factored into a pure `handle(body:via:)` so it's unit-tested without `WKScriptMessage`. `WebViewBridge.localDevConfiguration(handler:)` registers the handler on the user-content controller; `PreviewView` wires a per-webview `AnglesiteScriptHandler(router: LoggingEditRouter())`.
3. ✅ JS edit overlay (#17). Lives at `JS/edit-overlay/` (TS source) and builds to a single `Resources/edit-overlay/overlay.js` IIFE via esbuild — `scripts/build-overlay.sh` runs as a prebuild phase (uses the vendored Node when present, system `npm` otherwise; idempotent on the `npm ci` step via `node_modules/.bin/esbuild` as the canary). Modules: `selector.ts` (pure `:nth-of-type` CSS path; first-cut strategy, #18 will finalize), `messages.ts` (post over `window.webkit.messageHandlers.anglesite`, await replies on `window.anglesite._handleReply`), `overlay.ts` (DOM behavior: hover outline / click → `contentEditable=true` / blur → post on change / drop image on `<img>` → post `set-image` with base64). Injected via `WebViewBridge.makeOverlayUserScript(in:)` → `WKUserScript` at `atDocumentEnd`, all frames; missing bundle is non-fatal (preview just loads without edit affordances). Tests via vitest + jsdom (19 in `JS/edit-overlay/test/` covering selector, messages, hover, click-to-edit, idempotent install) plus the Swift-side `WebViewBridgeTests` for the user-script loader. Drop-image behavior is implemented but not unit-tested (jsdom's DataTransfer/FileReader make it fiddly — manual smoke instead).
4. ✅ **Selector strategy: server-side resolution (#18, decided 2026-05-13).** The overlay sends a structured `ElementInfo` payload — `{tag, id?, classes, nthChild, ancestors?, dataAnglesiteId?, dataTestId?, role?, ariaLabel?, textContent?}` matching the typedef in `anglesite/server/selector.mjs` — and the plugin invokes `buildSelector(info)` server-side. One source of truth for the priority order (`data-anglesite-id` > `data-testid` > `#id` > role/aria > stable classes > `tag:nth-child`), no fork-prone duplicated JS. `JS/edit-overlay/src/selector.ts` exposes `elementInfoFor(element)`; ancestors are root-first and stop at `<body>`. The bridge stays a relay: `EditMessage.selector` is `JSONValue` (validated as an object at decode), forwarded as-is by `MCPApplyEditRouter` to the `anglesite:apply-edit` tool when Phase 5 wires it up.
5. ✅ MCP client lifecycle + apply-edit round-trip wired (2026-05-22). `PreviewSession` (AnglesiteCore) now owns one `MCPClient` per site alongside its `AstroDevServer` — spawned together in `start(siteID:siteDirectory:)`, drained together in `stop()`, both tracked by `ProcessSupervisor.shared` so app-quit drains every child. Spawn defaults: vendored Node + bundled plugin's `server/index.mjs` resolved via `PluginRuntime`, `ANGLESITE_PROJECT_ROOT` set to the site path, source tag `mcp:<siteName>`. Graceful failure — if MCP can't spawn the session still reaches `.ready(url)`; only edit attempts fail (with the existing `EditReply.failed("MCP not running")` shape). `PreviewModel` builds an `MCPApplyEditRouter` wrapping a weak getter to `session.mcpClient` and exposes it as `editRouter`; `PreviewView`/`ContentView` thread it into `AnglesiteScriptHandler` (was `LoggingEditRouter`). End-to-end test in `AnglesiteBridgeTests/AppliesEditEndToEndTests` spawns the real bundled plugin against a tmp Astro-shaped fixture, drives `apply_edit` through a real `MCPClient`, asserts the file's bytes change — `XCTSkip`s cleanly when the sibling plugin checkout or its `node_modules` aren't present (CI provides both via `actions/checkout` + `npm ci` + `ANGLESITE_PLUGIN_PATH`). Cost: +1 Node process per open site (~80–150 MB on top of the existing `astro dev` process).

## Phase 5 — Source patcher (in the plugin repo, not the app) ✅

This work lands in `anglesite/server/` — the app repo just calls it.

1. ✅ `server/patcher.mjs` — three resolvers in priority order (`.mdoc` → Keystatic schema → `.astro` static text). Each returns `{file, range, replacement}` or `{refused, reason, detail?}`. Landed in `Anglesite/anglesite#295` → merged via #314.
2. ✅ `server/apply-edit-schema.mjs` — zod schemas for `apply_edit`, `edit-applied`, `edit-failed` (replaces the `messages.mjs` extension; tool name is `apply_edit` snake-case server-side, the WKWebView-side `type:` tag stays `"anglesite:apply-edit"`). Landed in `#296` → merged via #313.
3. ✅ `server/index.mjs` dispatch — wires the `apply_edit` MCP tool to the dispatcher. Landed in `#297` → merged via #315.
4. ✅ Hidden git branch undo — `server/edit-history.mjs` commits each successful patch to `anglesite/edits` via git plumbing (no working-tree-dirtying). Landed in `#298` → merged via #316.
5. ✅ Tests in `anglesite/test/patcher.test.js` + `apply-edit-dispatcher.test.js` + `edit-history.test.js` covering each resolver, ambiguous-match refusal, write-failed mapping, and the onApplied hook contract.
6. Bounce-to-Claude path remains deferred to v0.5 — for v0, ambiguous edits surface as `edit-failed` reasons (`no-match`, `dynamic-expression`, `ambiguous-match`); the app's plan is to render a "Can't edit this directly — try chat (coming soon)" sheet once the chat panel arrives in Phase 8.

**End-to-end verification (2026-05-22):** typed h1 edit in `~/Sites/smoke/src/pages/index.astro` flowed through the WKWebView overlay → `AnglesiteScriptHandler.decode` → `MCPApplyEditRouter` → bundled MCP server → dispatcher → atomic file write. Tracking issues `Anglesite/anglesite#294` and `Anglesite/Anglesite-app#19` closed. The `AppliesEditEndToEndTests` xctest gives this round-trip ongoing CI coverage.

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

1. Multi-window: `WindowGroup(for: SiteID.self)` so each site opens in its own window with its own dev server (per the multi-window decision above). A "Sites" launcher (window list / open / new) replaces the single-window sidebar; opening a window spins up that site's dev server, closing it tears it down.
2. Health badge polls `/anglesite:check` periodically.
3. Image drop → call `optimize-images` skill via MCP → write to `public/` → patch `src=`.
4. Undo affordance per edit in the chat panel, backed by the hidden git branch.

## Phase 10 — v2 polish

Per design doc §12: sandboxed App Store build (helper-tool architecture for Node), Quick Look, Spotlight, Settings polish.

---

## Cross-cutting decisions to lock in early

- **Multi-window — one window per site.** *(Decided 2026-05-12, overriding the earlier "single-window with tabs" recommendation.)* Each open site gets its own top-level window with its own dev server / preview / debug pane; switching sites = `⌘\`` / Window menu, not in-window tabs. Practically: `AnglesiteApp` already uses `WindowGroup`; Phase 9 swaps it to `WindowGroup(for: SiteID.self)` so each window is bound to a specific site, and the Phase 9 "sidebar" becomes a window-switcher / new-site launcher rather than an in-window list.
- **Chat history per-site** in `.anglesite/chat-history.jsonl`, included in the GitHub backup.
- **Swift architecture: plain SwiftUI + actors for supervisors.** No TCA for v0 — keeps the maintainer pool wide.
- **Two repos, coordinated:** changes spanning `anglesite/server/patcher.mjs` and the app land as paired PRs. Document this in `Anglesite-app/CLAUDE.md`.

## Suggested first PR to land

A single PR containing Phases 0 + 1 + a "hello world" that spawns embedded Node and prints `2` in the UI. That's the smallest slice that proves the riskiest assumption (notarized embedded Node works) and gives a foundation everything else builds on.
