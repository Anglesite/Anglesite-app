# Siri AI Smoke Matrix

**Issue:** [#237](https://github.com/Anglesite/Anglesite-app/issues/237) (parent epic [#135](https://github.com/Anglesite/Anglesite-app/issues/135) — System-wide MCP exposure; Siri AI phases A–D)
**Date:** 2026-06-20
**Related:**
[Siri AI integration design](../superpowers/specs/2026-06-11-siri-ai-integration-design.md) ·
[D.1 Intent MCP readiness audit](2026-06-17-d1-intent-mcp-readiness-audit.md) ·
[C.11 Phase C test-suite plan](../superpowers/plans/2026-06-17-c11-phase-c-test-suite.md) ·
[Siri edit-confirmation design](2026-06-19-siri-edit-confirmation-design.md)

## Why this exists

The repo has phase trackers for App Intents (A/B), View Annotations, Foundation Models,
Spotlight, and system-wide MCP (D). Each has unit coverage. What was missing is a single
**product-level acceptance matrix**: the specific Siri/Shortcuts phrases, the app states they
must work in, and the expected outcome — the checklist a human runs before tagging a DevID or
MAS build, anchored to automated fixtures so it can't silently drift.

This **complements, not replaces**, the Phase C test-suite audit and the D.5 manual MCP smoke.

## Scope — the nine supported workflows

Every row maps to a shipped intent in `Sources/AnglesiteIntents`. Most have a curated Siri phrase
in `AnglesiteShortcuts.appShortcuts`; two exceptions ship without a curated phrase and are reached
via Shortcuts / entity matching instead: `OpenSiteIntent` (an `OpenIntent` exercised via the
entity-resolution path) and `FindContentByTypeIntent` (reached via Shortcuts / entity match — the
10-phrase budget is full). Phrases below are verbatim from the shortcuts provider; `Anglesite`
is `\(.applicationName)` at runtime.

| # | Workflow | Intent | Curated Siri phrase(s) | Side effect | Confirms? | Returns |
|---|---|---|---|---|---|---|
| 1 | Open this site | `OpenSiteIntent` | *(no phrase — Spotlight/Shortcuts entity tap)* | read-only | no | — (opens UI) |
| 2 | Back up this site | `BackupSiteIntent` | "Back up my site with Anglesite" | creates content | no | `SiteEntity` |
| 3 | Audit this site | `AuditSiteIntent` | "Check my site with Anglesite" | read-only | no | `SiteEntity` |
| 4 | Deploy with confirmation | `DeploySiteIntent` | "Deploy my site with Anglesite" | publishes | **yes** | `SiteEntity` |
| 5 | Search content | `SearchContentIntent` | "What's on my site …" / "Search my site …" | read-only | no | `[ContentMatchEntity]` |
| 5b | Site status | `SiteStatusIntent` | "How is my site doing …" / "My site status …" | read-only | no | — (dialog) |
| 5c | Find content by type | `FindContentByTypeIntent` | *(no phrase — Shortcuts / entity match)* | read-only | no | `[PostEntity]` |
| 6 | Add page / post | `AddPageIntent` / `AddPostIntent` | "Add a page …" / "Add a post …" | creates content | no | `PageEntity?` / `PostEntity?` |
| 7 | Preview a page | `PreviewSiteIntent` | "Preview my site …" / "Open my site preview …" | read-only | no | — (opens UI) |
| 8 | Edit visible content with confirmation | `EditContentIntent` | "Edit this with Anglesite" / "Change this with Anglesite" | modifies content | **yes** † | — (dialog) |

† `EditContentIntent.perform()` calls `requestConfirmation` before any write (the dry-run →
confirm → apply flow). The `AnglesiteOperations` descriptor for `edit-content` still declares
`requiresConfirmation: false` with a `TODO(#239/#250)`; that flag flips when #239/#250 close.
The **runtime gate is live regardless** — see `EditContentIntentFlowTests` /
`EditContentIntentCancelTests`. The smoke-matrix coverage anchor (below) keys off the runtime
behavior, not the stale descriptor flag.

## Required app state per workflow

States to exercise during a manual pass. "Resolves site" = how the `site`/`element` parameter
is satisfied. Cold = app not running; Launcher = app open, no site window; Frontmost = a site
window is key; Preview = the WKWebView preview is focused (onscreen-awareness path).

| Workflow | Cold (no window) | Launcher open | Site window frontmost | Preview focused | MAS grant present | MAS grant missing |
|---|---|---|---|---|---|---|
| Open site | Launch + open; Siri prompts for site | Prompts for site, opens | No-op if same, else switches | n/a | opens | opens (read-only) |
| Back up | Launch; prompts for site | Prompts for site | Acts on frontmost site | n/a | runs | **fails closed** ‡ |
| Audit | Launch; prompts | Prompts | Acts on frontmost | n/a | runs | **fails closed** ‡ |
| Deploy | Launch; prompts; **confirm** | Prompts; confirm | Confirm; runs | n/a | runs after confirm | **fails closed** ‡ |
| Search content | Launch; prompts | Prompts | Searches frontmost | n/a | reads | reads (graph is app-owned) |
| Site status | Launch; prompts | Prompts | Status of frontmost | n/a | reads | reads |
| Find content by type | Launch; prompts | Prompts | Searches frontmost | n/a | reads | reads (graph is app-owned) |
| Add page/post | Launch; prompts | Prompts | Adds to frontmost | n/a | writes | **fails closed** ‡ |
| Preview | Launch + open preview | Opens preview | Navigates preview | re-navigates current | opens | opens |
| Edit visible content | n/a — needs onscreen element | n/a | n/a (no selection) | resolves `element`; **confirm**; writes | writes after confirm | **fails closed** ‡ |

‡ **Fail closed** = on MAS without the per-package security-scoped grant, a write/spawn operation
must surface a clear "open the site first / grant access" failure, **never** silently no-op
(CLAUDE.md: "Logs are sacred", "surface failures rather than allowing override"). The grant is
the `SiteWindow`-held bookmark; without an open window the sandboxed child can't reach `Source/`.

## Coverage classification

### CI-covered (deterministic — these gate every PR)

Anchored by `SmokeMatrixTests` (`Tests/AnglesiteIntentsTests/SmokeMatrixTests.swift`), which
asserts the matrix above stays in sync with the shipped code, plus the per-intent suites:

- **Entity resolution** — `SiteEntityQueryTests`, `ContentEntitiesTests`, `ContentMatchEntityTests`, `SiteEntityAnnotationTests`.
- **Intent dialog mapping** — `ContentIntentsTests` (pure `ContentDialogs`), `DeploySiteIntentTests`, `BackupSiteIntentTests`, `AuditSiteIntentTests`, `OpenSiteIntentTests`.
- **Confirmation / cancel paths** — `EditContentIntentFlowTests`, `EditContentIntentCancelTests`, `EditConfirmationDialogTests`, `EditContentIntentSiteUnavailableTests`, and `SmokeMatrixTests.editConfirmationGateBlocksWriteOnDecline` (the edit "Confirms? yes" cell made behavioral: a declined edit dry-runs but never writes). Deploy's *runtime* confirmation gate (`requestConfirmation` before publishing) can't run under `swift test` — no intentsd — so it is a manual row; CI pins the **registry declaration** (`requiresConfirmation: true`, only `.publishes` op) instead.
- **Content-graph fixtures** — `ContentPipelineE2ETests`, `ContentSpotlightIndexerTests`, `SpotlightIndexerTests`.
- **Operation-descriptor contract** — `OperationDescriptorTests`, `OperationDescriptorBehavioralTests`.
- **Chaining** (audit→deploy etc.) — `IntentChainingTests`.
- **Window routing** (open/preview side effects) — `WindowRouterTests`.
- **Readiness probes** — `SiriReadiness*ProbeTests`.

### Manual-only (NOT represented as green CI)

Apple's Siri runtime and Foundation Models tool calls are opaque to `swift test`; these are
checked by hand against a fixture site and recorded in the PR description, never faked green:

- **Spoken-phrase recognition** — that Siri actually maps each phrase to its intent. `appShortcuts` is type-erased `[AppShortcut]`; Apple exposes no public read-back of the phrase→intent map, so only the **count** is asserted in CI (`AnglesiteShortcutsTests`). Phrase wording is verified in Shortcuts.app / "Hey Siri".
- **Onscreen-element resolution** — `appEntityUIElementProvider` feeding "edit this" / "change this" from the focused preview. The provider shaping is unit-tested (`PreviewAnnotationProviderTests`); the live Siri hand-off is manual.
- **Foundation Models NL interpretation** — `EditContentIntent`'s on-device instruction → structured op. The interpreter seam is faked in CI (`EditInterpreterOverride`); the real on-device model output is manual (and unavailable on the CI runner).
- **System-wide MCP bridge** — Phase D / #135, not yet built (`SystemMCPBridgeProbe` truthfully reports `.unsupported`). The D.5 MCP smoke covers this separately.
- **MAS sandbox grant present/missing** — the security-scoped bookmark behavior needs a real sandboxed `AnglesiteMAS.app` launch (blocked on hosted CI per CLAUDE.md), so the "fail closed" column is a manual MAS pass.
- **Deploy's live Siri confirmation prompt** — `requestConfirmation` needs intentsd / a registered app, absent under `swift test`. CI pins only the registry declaration; verify the actual "Deploy … to production?" prompt (and that declining aborts) by hand. The *edit* confirmation gate is the one with a behavioral CI test, via the `ConfirmationOverride` seam.

## DevID vs MAS

The same matrix applies to both targets. Differences to watch on the MAS pass:

- The "MAS grant present/missing" columns only apply to `AnglesiteMAS`; on DevID (sandbox off) writes work without the bookmark.
- Chat / Sparkle / `gh` are compiled out of MAS, but none of the nine workflows depend on them, so the matrix is identical.
- Run the manual pass once per target before tagging a release.

## How to run a pass

1. **CI deterministic layer:** `swift test --package-path .` (needs Xcode 27 / Swift 6.4 — the
   `AnglesiteIntentsTests` target is `#if compiler(>=6.4)`-gated in `Package.swift`, so it is
   skipped on the older CI runner). `SmokeMatrixTests` fails loudly if the matrix and the
   shipped intent/operation registry diverge.
2. **Manual layer:** with a fixture site open, walk each "Required app state" cell for the
   manual-only rows, on both DevID and MAS builds. Record results in the PR.
