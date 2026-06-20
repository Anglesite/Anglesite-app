# On-device summaries for deploy logs and audit results (#93)

**Issue:** #93 (Siri AI Phase C follow-on, `phase-c`)
**Depends on:** Phase C (#134) — shipped. Reuses `FoundationModelAssistant.generateStructured`, `AssistantContext`, and the `@Generable` pattern in `GenerableTypes.swift`.
**Status:** Design approved 2026-06-19.

## Goal

Give the user concise summaries of two verbose result surfaces:

1. **Audit results** — a one-line overview of findings ("3 SEO warnings, 1 accessibility issue, no security findings").
2. **Deploy logs** — when a deploy *fails*, an on-device, natural-language explanation of what went wrong and how to fix it.

These are two independent surfaces with deliberately different implementations. Audit is **deterministic** (the data is already structured). Deploy failure is **model-generated** (the cause is buried in unstructured log text).

## Decisions (locked during brainstorming)

| Question | Decision |
|---|---|
| Audit summary generation | **Deterministic only** — pure function over `AuditReport`. No model call. |
| Deploy summary trigger | **Auto on failure only.** Success keeps the existing deterministic "Deployed to `<url>`" line. |
| Deploy failure output shape | **Structured `@Generable`** — `summary`, `likelyCause`, `suggestedFix`, rendered with distinct fields. |

Success deploys are intentionally left untouched: `DeployModel.Phase.succeeded(url:duration:)` and `DeployDrawerView` already show the URL; no model compute is spent on the common path.

## Architecture

Logic lives in `AnglesiteCore` wherever it can, so it is covered by `swift test` on CI. The hard constraint: **`AnglesiteCore` must compile on the older CI runner where `FoundationModels` is absent.** Therefore all public, view-facing types stay non-gated, and only the code that actually touches the model is wrapped in `#if compiler(>=6.4)` — the exact pattern already used by `GenerableTypes.swift`, `FoundationModelAssistant.swift`, and `ApplyEditTool.swift`.

### Components

| Unit | Module | Gating | Purpose |
|---|---|---|---|
| `AuditReport.summary` (computed property) | `AnglesiteCore` | none | Deterministic one-line overview: counts findings by category/severity, plus a skipped-runner note. |
| `DeployLogDigest.extract(from:)` | `AnglesiteCore` | none | Pure `String -> String`. Drops `npm run build` noise, keeps the wrangler/error tail, caps length to the on-device context budget. |
| `DeployFailureSummary` | `AnglesiteCore` | **none** | Plain view-facing result value: `summary: String`, `likelyCause: String`, `suggestedFix: String`. |
| `GeneratedDeployFailureSummary` | `AnglesiteCore` (`GenerableTypes.swift`) | `#if compiler(>=6.4)` | `@Generable` intermediate the model fills; mapped to `DeployFailureSummary`. |
| `DeployFailureSummarizing` (protocol) | `AnglesiteCore` | none | `func summarize(failureLog:context:) async -> DeployFailureSummary?`. Returns `nil` when the model is unavailable or generation fails. |
| `FoundationModelDeploySummarizer` | `AnglesiteCore` | `#if compiler(>=6.4)` | Default conformer. Calls `FoundationModelAssistant(tier: .onDevice).generateStructured(resultType: GeneratedDeployFailureSummary.self)`, maps to `DeployFailureSummary`, catches `AssistantError.unavailable` (and any throw) → `nil`. |

### Why the plain / `@Generable` split

`@Generable` expands to code that imports `FoundationModels`, which does not exist on the CI toolchain. If `DeployModel`, `DeployDrawerView`, or any CI-compiled `AnglesiteCore` test referenced the `@Generable` type directly, the Core target would fail to build on CI. So:

- `DeployFailureSummary` (plain struct) is the currency everything non-gated speaks.
- `GeneratedDeployFailureSummary` (`@Generable`) exists only inside the gated summarizer and is mapped to the plain type before crossing the gate.

This mirrors the existing `GeneratedEditCommand` / `GeneratedPageMeta` / `GeneratedAltText` naming.

## Data flow

### Audit (deterministic)

```
AuditCommand → AuditReport → AuditReport.summary (pure) → AuditSheetView (top of findings list)
```

`AuditReport.summary` counts `findings` grouped by `category` and `severity` and renders a compact sentence. Rules:

- No findings and nothing skipped → "No issues found."
- Findings present → human-readable counts, e.g. "2 security warnings, 1 accessibility issue". Pluralize correctly. Order by category severity weight (security, accessibility, performance, seo) for stable output.
- Any `runnersSkipped` → append a note: "performance check couldn't run." (one clause per skipped category).

The exact phrasing is finalized in the implementation plan; the contract is: deterministic, total (never throws), and stable for a given `AuditReport`.

### Deploy failure (model-generated)

```
DeployCommand → DeployModel.Phase.failed(reason:exitCode:)
   → DeployLogDigest.extract(from: logText)            // pure, non-gated
   → DeployFailureSummarizing.summarize(...)            // async, may return nil
       → FoundationModelAssistant.generateStructured(GeneratedDeployFailureSummary)
       → map → DeployFailureSummary
   → DeployModel.failureSummary / summarizing flag
   → DeployDrawerView renders summary + likelyCause + suggestedFix
```

`DeployModel` (in `AnglesiteApp`, `@MainActor @Observable`) gains:

- `private(set) var failureSummary: DeployFailureSummary?`
- `private(set) var summarizing: Bool`
- an injected `summarizer: DeployFailureSummarizing` (default-param, consistent with the existing `command` / `keychain` / `verifier` injection in `DeployModel.init`).

When `result` resolves to `.failed`, `DeployModel` extracts the digest, sets `summarizing = true`, awaits `summarize(...)`, stores the result (or leaves `failureSummary == nil`), and clears `summarizing`. The `.succeeded` and `.blocked` paths are unchanged.

The default summarizer is chosen at the gate:

```swift
static func makeDefault() -> DeployFailureSummarizing {
    #if compiler(>=6.4)
    return FoundationModelDeploySummarizer()
    #else
    return NoopDeploySummarizer()   // always returns nil
    #endif
}
```

The app target always compiles with Xcode 27, so it always gets the real summarizer; the no-op default only exists so non-Xcode-27 builds and tests link.

## Error handling & fallback

- **Model unavailable** (older OS, no Apple Intelligence, MAS sandbox quirk): `generateStructured` throws `AssistantError.unavailable`; the summarizer returns `nil`; `DeployDrawerView` falls back to today's raw `reason` + `exitCode` + scrollable log. No regression.
- **Generation throws / times out:** treated identically — `nil`, raw fallback.
- **Empty or trivially short log:** `DeployLogDigest.extract` still returns the best available text; if the digest is empty the summarizer returns `nil` without calling the model.
- The summary is **advisory** — the raw log remains visible/copyable in all cases, so a hallucinated cause can never hide the ground truth.

## View changes

- `AuditSheetView`: render `report.summary` as a header line above the findings list.
- `DeployDrawerView`: in the `.failed` branch, add a "Summary" section — `ProgressView` while `summarizing`, then `summary` with `likelyCause` and `suggestedFix` shown as distinct rows when present. When `failureSummary == nil` and not summarizing, render nothing extra (existing raw failure UI stands).

## Testing

### Core (runs on CI, `#if compiler(>=6.4)`-independent)

- `AuditReport.summary`: empty report; single finding; multiple categories; pluralization (1 vs N); severity wording (critical/warning/info); one and multiple skipped runners; findings + skipped together.
- `DeployLogDigest.extract`: strips `npm run build` noise; preserves the wrangler error tail; enforces the length cap; handles empty input and input with no recognizable deploy phase.

### Xcode-27-only (gated)

- `GeneratedDeployFailureSummary` → `DeployFailureSummary` mapping.
- `FoundationModelDeploySummarizer` unavailable-path: a seam (injected availability/model stub or a thrown `AssistantError.unavailable`) returns `nil` rather than propagating.

### App target (`DeployModel`, not on CI — thin glue)

- With a stub `DeployFailureSummarizing` returning a canned `DeployFailureSummary`: `.failed` sets `summarizing` then `failureSummary`; `.succeeded` and `.blocked` leave both untouched.
- Stub returning `nil`: `failureSummary` stays `nil`, `summarizing` ends `false`.

## Out of scope (YAGNI)

- No model summary for successful deploys (deterministic URL line already exists).
- No model-generated audit narrative (deterministic counts are sufficient; the issue explicitly prefers this).
- No Private Cloud Compute tier for this feature — on-device only; the digest is capped to the ~4K on-device context.
- No persistence of summaries across app launches (regenerated on demand from the captured log).
