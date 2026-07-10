# Slice 6: Content Help on Foundation Models — copy-edit, social-media, repurpose

**Date:** 2026-07-10
**Status:** Design (no implementation yet)
**Issue:** #465, part of the Claude Code removal epic #459
**Parent spec:** [`2026-06-20-claude-code-removal-roadmap-design.md`](2026-06-20-claude-code-removal-roadmap-design.md) §5 Bucket 5, §6 Slice 6, §8 context-ceiling risk

---

## 1. Scope

Re-implement the three headline Bucket-5 content-help capabilities — **copy-edit**,
**social-media**, and **repurpose** — as FoundationModels-backed Swift, each reachable
from chat, Siri, and GUI, with no `claude --print` involvement, plus the **shared
kernel** (brand voice, chunking, tier seam) that the remaining Bucket-5 capabilities
will reuse.

**Out of scope (fast-follows riding this kernel):** `reputation`, `animate`, `i18n`
content translation, `convert`/`import` content cleanup, commerce tier/product copy;
the deploy-time `reports/copy-edit-report.md` hook; real PCC escalation (slice 5,
#464); `ExternalLLMBackend` (cross-platform port P5, #570).

## 2. Decisions (settled during brainstorming)

| Decision | Choice |
|---|---|
| Capability scope | Headline trio + shared kernel; the other five Bucket-5 items are follow-ups. |
| Slice-5 relationship | Define the tier-seam factory as an explicit shared seam; don't block on #464. Whichever slice lands first builds it; the other adopts it. Noted on both issues. |
| Context ceiling (§8 risk) | **Chunk-first, tier-ready.** All three capabilities are correct at the ~4K on-device window via deterministic per-page chunking. `FoundationModelTier.privateCloudCompute` remains the (currently stubbed) escalation knob: when real PCC lands, chunks get bigger — the seam changes, not the capabilities. |
| Brand voice | Sourced from the shipped `ProjectConventions` engine (`Config/conventions.json`), not `docs/brand-voice.md`. Port the copy-edit skill's 5-question voice interview as an FM-guided flow writing `.userOverride` entries. Sites edited outside the app keep working because conventions re-infer from content. |
| Architecture | Shared kernel + per-capability generators (the proven slice-2/4 shape), not a generic content-help engine. |

## 3. Baseline this builds on

- The chat brain is already FM-only: `ChatModel` depends on `any ConversationalAssistant`,
  composed in `SiteAssistantSessionFactory` as
  `KnowledgeAugmentedAssistant(base: FoundationModelAssistant(tier: .onDevice, …))`.
  `ClaudeAgent` no longer exists in `Sources/`. This slice is **additive**.
- `FoundationModelTier.privateCloudCompute` is a stub (same on-device session,
  advertised 32K context); there is no real escalation substrate yet.
- `ProjectConventions` (#313) shipped: engine, store, extractor, `ProjectStyleGuideView`.
  Only `AltTextPromptBuilder` consumes it; the spec's general `formattedGuidance`
  natural-language preamble never shipped.
- `SiteContentGraph` enumerates pages/posts per site; `SiteGraphNodeExplainer` (#614)
  is the proven "deterministic fact-gathering + hard caps + facts-only prompt" pattern
  for living inside the 4K window.
- Established patterns to follow: `Factory.makeDefault()` + `#if compiler(>=6.4)`-gated
  concrete struct with pure helpers above the gate (CI on Xcode 26.x); `@Generable`
  output types centralized in `GenerableTypes.swift`; FM `Tool`s assembled per-session
  in `FoundationModelAssistant.conversationTools(…)` (`SetupIntegrationTool` is the
  canonical template); three front-doors per capability (FM Tool / App Intent / GUI).

## 4. Shared kernel (AnglesiteCore)

### 4.1 `BrandVoiceGuidance`
Implements the style-guide spec's unshipped `formattedGuidance`: builds a
natural-language prompt preamble from `ProjectConventions.writing` — tone descriptors,
brand terms with canonical capitalization, sentence-length/punctuation stats — plus
business type from site config. Generalizes `AltTextPromptBuilder`; alt text migrates
to it opportunistically. Pure (no FM calls), above the compiler gate, unit-tested.

### 4.2 Brand-voice interview
The copy-edit skill's 5-question interview (audience, tone, personality words, phrases
to use/avoid, formality) ported as an FM-guided conversational flow. Answers are
written as `.userOverride` entries into `ProjectConventionsStore` (tone descriptors,
brand terms, audience). Surfaced in `ProjectStyleGuideView` ("Set up brand voice…")
and invocable from chat. Replaces the skills' shared `docs/brand-voice.md` contract;
gives new/sparse sites a real voice signal where inference is weak.

### 4.3 `SiteContentChunker`
Deterministic per-item iteration over `SiteContentGraph` (pages + posts) producing
capped plain-text chunks:

- `.md`/`.mdoc`: frontmatter-stripped markdown body.
- `.astro` inline text: a simple tag-strip extractor (v1 — not a full HTML parser;
  this fills the "no HTML→text in Core" gap only far enough for copy auditing).
- Caps follow the `SiteGraphExplainPrompt` pattern: hard character limits, "…and N
  more" elision, facts-only instructions. Every FM call fits the ~4K window today.

### 4.4 Tier seam (shared with slice 5)
Capabilities never construct `FoundationModelAssistant` directly; they take an
injected `ContentAssistant` built by a single factory function that accepts a
`FoundationModelTier`. Heavy operations request `.privateCloudCompute` — today the
stub, later real PCC or slice 5's escalation logic. Because chunking guarantees
correctness at 4K, a bigger window is purely an optimization (larger chunks, fewer
calls). This factory is the convergence point named on #464/#465.

### 4.5 Output types
All `@Generable` output structs (`GeneratedPageCopyFindings`,
`GeneratedSocialProfileCopy`, `GeneratedContentPillars`, `GeneratedCalendarWeek`,
`GeneratedPlatformPost`, …) live in `GenerableTypes.swift` with `@Guide` descriptions,
per convention.

## 5. Capabilities

Each: deterministic gatherer → structured FM generator → three front-doors.

### 5.1 Copy-edit — `CopyEditAuditor`
- **Generate:** per chunk, one guided-generation call — `BrandVoiceGuidance` preamble +
  the skill's 10-point checklist (clarity, benefits-over-features, voice consistency,
  CTAs, scannability, you/we ratio, jargon, social proof, missing info, mobile
  readability) encoded as `@Guide` descriptions — returning `GeneratedPageCopyFindings`
  (per finding: category, severity, quoted excerpt, suggested rewrite).
- **Aggregate (deterministic):** group by page, sort by severity → `CopyEditReport`.
  Per-chunk FM failures degrade to a partial report listing skipped pages — never
  abort, never silently drop.
- **Apply:** findings land as **annotations** via the existing annotation store, so
  they appear in navigator/preview like any annotation; accepting a suggested rewrite
  routes through the existing `apply_edit` diff-confirm pipeline. No new apply
  machinery; "never batch-rewrite" is preserved structurally.
- **Front-doors:** GUI report view ("Review Copy…") with per-finding Apply/Dismiss;
  App Intent returning the summary; chat Tool `reviewCopy` (page-scoped answers
  inline; site-scoped kicks off the audit).

### 5.2 Social media — `SocialMediaPlanner`
- **Deterministic:** business-type → platform recommendation table (ported from the
  skill/SMB docs as Swift data), cadence rules, calendar date math.
- **Generate:** profile bios (per-platform char limits), 3–5 content pillars (80/20
  rule), calendar entries generated **week-by-week** — one structured call per week
  keeps each call inside the window.
- **Output:** Swift renders the structured plan to `docs/social-calendar.md` in
  `Source/` (update-in-place, git-visible, portable). The FM generates content;
  deterministic code owns the file format. Never posts anywhere.
- **Front-doors:** GUI planner panel; App Intent ("Plan my social media"); chat Tool.

### 5.3 Repurpose — `PostRepurposer`
- **Deterministic:** load one post's frontmatter + body, construct its canonical URL
  from site config, platform-spec table (Instagram 2200/hashtags/no URLs, Facebook
  <500 + URL, Google Business 1500, Nextdoor, X 280, Bluesky 300).
- **Generate:** one structured call per platform. **Char limits enforced in Swift:**
  validate → one retry with a "shorter" instruction → refuse with a message. Never
  silently truncate generated copy.
- **Output:** variants UI with copy buttons + `ShareLink`; when the owner pastes
  published URLs back, the `syndication:` frontmatter write-back (POSSE u-syndication
  trail) is deterministic.
- **Front-doors:** context-menu action on posts in the navigator; App Intent
  ("Repurpose my latest post"); chat Tool.

## 6. Error handling & privacy

- FM unavailable (`SystemLanguageModel.availability`): GUI entry points render
  **disabled-with-explanation** per the LLM policy (§2 of the roadmap spec, amended
  2026-07-08) — never a silent degraded call; chat Tools return a graceful
  "not available on this Mac" string; Intents throw a user-visible error.
- Mid-audit chunk failures → partial results with gaps named (see §5.1).
- Everything runs on-device; **no network I/O anywhere in this slice**; nothing is
  posted on the owner's behalf (parity with the skills).

## 7. Testing

- Pure, above-the-gate, unit-tested in `AnglesiteCoreTests` on CI: prompt builders
  (voice preamble, checklist, platform specs), chunker/text extractor, report
  aggregation, char-limit validation, calendar-markdown renderer.
- FM-touching structs exercised through the `ContentAssistant` protocol with fakes
  (existing pattern). GUI models take injected protocols.
- `swift test` before pushing; `AnglesiteIntentsTests` needs Xcode 27 / Swift 6.4.

## 8. Rollout & epic hygiene

- No app-side `claude --print` path remains to delete. The plugin-side `copy-edit` /
  `social-media` / `repurpose` markdown skills retire with slice 7's plugin-repo
  conversion (noted on #466).
- Claim #465 (`status:in-progress`); comment on #464/#465 naming the §4.4 factory as
  the shared tier seam.
- Follow-ups filed after landing: remaining Bucket-5 capabilities on the kernel;
  deploy-time copy-quality report hook.
