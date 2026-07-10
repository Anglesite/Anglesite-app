# Slice 5 (#464): Theme apply + design-interview on FM/PCC

**Status:** Approved design, not yet implemented.
**Epic:** Claude Code removal (#459), Slice 5 (P3).
**Spec reference:** [`2026-06-20-claude-code-removal-roadmap-design.md`](2026-06-20-claude-code-removal-roadmap-design.md) §6 Slice 5, §5 Bucket 3 & Bucket 5, §8 PCC risk.

## Scope

This slice covers two related but architecturally distinct capabilities from the plugin's `themes`/`freedesignmd`/`design-interview` skills:

1. **Theme apply** (Bucket 3 — deterministic): choosing and applying a built-in or freedesignmd theme to an existing site.
2. **design-interview** (Bucket 5 — hybrid): a multi-turn conversation that derives a bespoke `DesignAxes`/palette, generative where the plugin skill used free-form LLM reasoning.

Both converge on the same deterministic write path, so they're designed together even though their front doors and testability differ sharply.

**Explicitly out of scope for this slice:**
- `design-import` (scraping/inferring design from an external site) — separate skill, not touched here.
- Favicon/manifest/`ai-images` regeneration, which the plugin's `design-interview` also performs — this slice covers axes/palette/tokens/`DESIGN.md`/`brand.md` only.
- Retiring the plugin skills — that happens in Slice 7 (#466), once both Swift front doors are Claude-free.

## Data model

New types, ported from the plugin's `scripts/design.ts` (no Swift equivalents exist today):

- `DesignAxes` — `Codable` struct of 0–1 sliders (formality, energy, density, etc.), mirroring the skill's axis vocabulary.
- `DesignPalette` — colors/fonts derived from axes and/or freedesignmd tokens.
- `DesignDraft` — `{ axes: DesignAxes, palette: DesignPalette, rationale: String?, sourceThemeID: String? }`. The convergence point for both flows.
- `Theme` — already exists (`Sources/AnglesiteCore/ThemeCatalog.swift`), reused unchanged for the 9 built-in quick-picks.

`DesignApplyService` (new, `AnglesiteCore`): `apply(_ draft: DesignDraft, to site: AnglesitePackage) -> Result<AppliedDesign, DesignApplyError>`. Ports `designToTokensCss()`, `createDesignConfig()`, the contrast check, and the `docs/brand.md` update from the skill. Pure and synchronous — no FoundationModels dependency, fully unit-testable, and shared by both flows below so there is exactly one "write design to disk" implementation.

## Theme-apply wizard (Bucket 3)

`ThemeApplyWizardModel` (`@MainActor @Observable`, `AnglesiteCore`), following the shape of the existing `IntegrationWizardModel` (PR #283):

```swift
enum Step {
    case pickSource       // built-in quick-picks vs. freedesignmd catalog
    case pickBuiltIn      // existing ThemeCatalog entries
    case browseFreedesignmd
    case fmAssist          // optional, only if FoundationModelAssistant reports .available
    case review
    case applying
}
```

- **pickBuiltIn**: unchanged, reuses `ThemeCatalog`.
- **browseFreedesignmd**: deterministic tag filter over the freedesignmd catalog (121 entries). The business-type → tag table is ported from the skill as static Swift data. The catalog JSON itself is fetched and cached; the *filter* over it is pure decision-tree logic, no LLM.
- **fmAssist** (optional): if `FoundationModelAssistant` availability is `.available`, offer a free-text "describe your vibe" box that re-ranks the already tag-filtered shortlist via one on-device FM call. This is bounded ranking over a short list — always fits the on-device 4K context, never escalates to PCC.
- **review**: shows the resolved `DesignDraft` (theme → axes/palette translation) before writing.
- **applying**: calls `DesignApplyService.apply`.

**Front-door parity**, mirroring the integration-wizard triad:
- GUI: `ThemeApplyWizard.swift` (SwiftUI sheet, `AnglesiteApp`), mirrors `IntegrationWizard.swift`.
- App Intent: `ApplyThemeIntent`.
- Chat: `SetupThemeTool`, an FM `Tool` using the same confirm-then-apply pattern as `SetupIntegrationTool` (plan, present, re-invoke with `apply: true`).

## design-interview conversation (Bucket 5)

`DesignInterviewModel` (`@MainActor`, wraps a `FoundationModelAssistant` session):

```swift
enum ConversationStage { case intent, mood, brandAnchor, axisConfirmation, done }
```

- Each stage is a `converse()` turn against a stage-specific, deterministically-built grounding prompt (following the `SiteGraphExplainPrompt` pattern — prompts are built from typed data, not ad-hoc string concatenation).
- The assistant replies with a structured (`@Generable`) type, not free text, which updates a live `DesignDraft`. A GUI slider/palette-preview panel observes the same `DesignDraft` and lets the user nudge sliders directly; a direct nudge re-seeds the next turn's grounding prompt.
- **"design it for me" escape hatch**: skips straight to `axisConfirmation` using FM-inferred defaults from business-type plus any free text supplied.
- `axisConfirmation` hands the finished `DesignDraft` to `DesignApplyService.apply` (the same call the wizard uses), plus one more on-device FM call to produce `generateDesignRationale()`'s prose — this is summarizing an already-bounded draft, not open brand generation, so it stays on-device.

**Front-door parity**: chat-first — the FM tool *is* the primary interface. The GUI panel mirrors state live rather than being a separate flow. Siri gets a single `StartDesignInterviewIntent` that opens chat pre-seeded at the `intent` stage.

### PCC escalation (real implementation, not the existing stub)

`FoundationModelAssistant.FoundationModelTier.privateCloudCompute` currently just runs on-device with a log message — no real escalation exists anywhere in the codebase. This slice implements it for real:

- `FoundationModelAssistant` gains an `escalate(reason:)` path.
- Triggers: (a) the brand-anchor stage's cumulative context would exceed the on-device 4096-token ceiling, or (b) the user explicitly requests "better"/more creative results.
- **Before the real implementation lands**, a validation spike confirms Apple's PCC round-trip is actually callable from both DevID and MAS builds (§8 risk in the roadmap spec). This spike is the first task in the implementation plan, not a deferred follow-up — if PCC isn't reachable, the escalation design needs to change before the rest of this slice is built on top of it.

## Testing strategy

- `DesignApplyService`, `DesignAxes`/`DesignPalette` transforms, freedesignmd tag-filter matching, and theme→axes translation: full Swift Testing unit coverage, no FM dependency, runs on CI.
- `FoundationModelAssistant`'s prompt-builders and response-parsing: unit-testable via fake `LanguageModelSession` responses, following the existing `#if compiler(>=6.4)` gating pattern.
- The live conversation loop, slider↔chat state mirroring, and actual FM/PCC calls: not testable on CI (hosted-app tests can't launch on CI's macOS-15 runners). Covered by manual GUI smoke pre-release, paired with the still-owed #491 smoke test in one manual pass.
- PCC round-trip validation: the spike itself is the acceptance test for that piece.

## Architecture rationale

Two focused models (`ThemeApplyWizardModel`, `DesignInterviewModel`) funneling into one shared `DesignApplyService`, rather than a single unified state machine. This keeps the deterministic half (theme-apply) independently testable and simple, while the generative half (design-interview) isn't forced into a flat wizard `Step` enum it doesn't fit. The cost is two models instead of one, but they share the one piece that actually matters for correctness — the write path.
