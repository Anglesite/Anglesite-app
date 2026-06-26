# Retiring Claude Code: Migration Roadmap to Deterministic Swift + Apple Intelligence

**Date:** 2026-06-20
**Status:** Design / roadmap (no implementation yet)
**Goal:** Make Anglesite usable by non-technical people by removing the Claude Code
dependency entirely and replacing it with deterministic Swift/TypeScript plus Apple
Intelligence (on-device Foundation Models, escalating to Private Cloud Compute).

---

## 1. Why

Today the app's "intelligence" is Claude Code: a `claude --print` subprocess that reads
56 markdown skills and orchestrates bash/npm/MCP calls. That requires the `claude`
binary, an Anthropic account, and a power-user mental model. For the target audience —
non-technical site owners driving the app by voice (Siri) and GUI — that dependency is
the wrong substrate.

This roadmap drives to **full removal**: the shipped app has no `claude` binary, the
plugin stops being a Claude plugin, and `ClaudeAgent` is deleted. Everything it did is
re-homed onto deterministic code or Apple Intelligence.

## 2. Locked decisions

These were settled during brainstorming and constrain everything below.

| Decision | Choice |
|---|---|
| **End-state for Claude Code** | Full removal. No `claude` binary, no Claude-plugin loading, `ClaudeAgent` deleted. |
| **Generative backstop** | Apple Intelligence only — on-device Foundation Models, escalating to Private Cloud Compute (PCC). **No external LLM APIs, ever.** |
| **Deterministic substrate** | Port hot paths to native Swift; keep Node only for things that need the JS ecosystem (Astro build, Sharp, Satori, Pagefind, Keystatic). |
| **JS execution location** | **All JS runs inside the container** (the Node sidecar — Astro, Sharp, Satori, Pagefind, Keystatic, `apply_edit`/`undo_edit`) — in-guest (#59/#66/#69), reached over the in-container MCP HTTP/WS transport (#64), **not** host-spawned. The embedded host Node + JIT re-sign apparatus retires once the container runtimes land (#70). Until then, the sidecar stays host-spawned as today (interim only). |
| **Anything that exceeds even PCC** | Simplified or retired — not shipped as a degraded cloud call. |

## 3. The interface today — three layers

The sub-agent survey confirmed the boundary splits into three layers, and only one of
them is actually a Claude dependency.

**Layer 1 — Plugin MCP server (`node server/index.mjs`): already 100% deterministic.**
All 8 tools — `apply_edit`, `undo_edit`, `list_content`, `create_page`, `create_post`,
`add_annotation`, `list_annotations`, `resolve_annotation` — are pure file / git /
selector-patching operations with no LLM. The app already calls them directly from Swift
via `MCPClient` over stdio. This is a Node *sidecar*, not a Claude dependency.

**Layer 2 — Apple Intelligence (FoundationModels): already on-device, no Claude.**
Already shipping: `FoundationModelEditInterpreter` (Siri NL edit: interpret → dry-run →
confirm → apply), `AltTextGenerator` (on-device vision), `FoundationModelDeploySummarizer`,
and `FoundationModelAssistant` (FM chat with `ApplyEditTool` + `SpotlightSearchTool`
tool-calling). The tool-calling orchestration pattern we need is **already proven here.**

**Layer 3 — Claude Code (`claude --print --plugin-dir …`): the only real dependency.**
Two things, and only these, flow through it:
- The **chat-panel brain** (`ClaudeAgent`) — open-ended conversation and deciding which
  tools to call.
- The **56 skills as prose** — markdown that only "runs" because an LLM reads and follows
  it, shelling out to bash/npm/MCP. The prose *is* the dependency; it cannot survive
  without an LLM interpreting it.

Removing Claude Code = retiring Layer 3 by absorbing its deterministic guts into Layers 1
and 2 and converting its prose skills into callable tools.

## 4. Target architecture: one capability → one implementation → many front-doors

The organizing principle. Every capability is implemented **once**, as a deterministic
tool or an FM-backed function, and exposed through up to three front-doors:

```
                 ┌───────── chat panel (FoundationModelAssistant, FM brain)
   capability ───┼───────── Siri / Spotlight (App Intent)
   (one impl)    └───────── GUI control / wizard (non-technical default)
```

- The **chat panel survives** but re-homes from `ClaudeAgent` to the existing
  `FoundationModelAssistant`. For non-technical users it's optional; Siri + GUI are the
  primary front-doors.
- The FM brain does **tool-calling**, not prose-following. Each migrated capability
  registers as an FM `Tool` (already how `ApplyEditTool` works).
- No capability is implemented twice. A GUI "Add contact form" button, "Hey Siri, add a
  contact form," and asking in chat all call the same Swift/sidecar function.

## 5. Capability taxonomy

Every MCP tool and skill sorts into one of six buckets. Hybrids (deterministic scaffold +
generative copy) appear in two buckets with the split called out.

### Bucket 1 — Hot-path → native Swift
High-frequency deterministic operations that are cheap to port — pure filesystem, JSON,
and git work with no HTML/AST parsing. Ported off the Node sidecar into Swift to cut
subprocess hops.

- `create_page`, `create_post` (template expansion + git)
- `list_content` (filesystem scan → structured JSON)
- `add_annotation` / `list_annotations` / `resolve_annotation` (JSON store)

**Decision:** `apply_edit` / `undo_edit` are deliberately **not** here — they stay in the
Node sidecar (Bucket 2). Their selector resolver/patcher (`selector.mjs`, `patcher.mjs`)
parses HTML/Astro, which a Swift port would have to reimplement against an HTML/AST parser
with Astro-component awareness. Not worth the risk for no AI benefit; the sidecar already
does it correctly and is called directly from Swift.

### Bucket 2 — JS-ecosystem → bundled Node sidecar
Keep in Node because they depend on the JS ecosystem (or on parsing HTML/Astro); just stop
routing them through Claude. **End-state: all of this JS runs inside the container** (#59),
reached over the in-container MCP HTTP/WS transport (#64) — not host-spawned. (Interim, until
the container runtimes land, they remain a host-spawned sidecar called directly as today; the
in-guest move is what lets the embedded host Node retire — #70.)

- `apply_edit` / `undo_edit` — selector resolve + patch + git per-edit commit. Stays in
  the sidecar: the patcher parses HTML/Astro and a Swift reimplementation buys nothing.
- Astro dev server + production build
- Sharp — image optimization (`optimize-images`)
- Satori — OG image generation (`og-images`)
- Pagefind — on-site search index (`search`)
- Keystatic — form/collection backends (`forms`, `inbox`, `membership`)

### Bucket 3 — Deterministic wizard → Swift + App Intent + GUI
These read as conversational skills but are really decision-trees over templates and
config. No model needed. Each becomes a Swift flow with an App Intent and a GUI wizard.

- **Infra/ops:** `start`, `deploy`, `check`, `backup`, `export`, `update`, `stats`
- **Integrations (scaffold + config):** `contact`, `consent`, `booking`, `newsletter`,
  `podcast`, `pwa`, `redirects`, `share`, `tracking`, `donations`, `giscus`, `indieweb`,
  `menu`, `inbox`, `membership`
- **Commerce scaffold:** `add-store`, `buy-button`, `lemon-squeezy`, `paddle`, `snipcart`,
  `shopify-buy-button` *(scaffold/config only — tier/product copy is Bucket 5)*
- **DNS/domain:** `domain`
- **Design application:** `themes`, `freedesignmd` (apply step), `design-import`
- **Utilities:** `qr`, `redirects`, `testimonials` (collection/moderation scaffold)

### Bucket 4 — On-device Foundation Models (structured generation)
Short, structured generation that fits the ~3B / ~4K-context on-device model via guided
generation. Some already shipped (✅).

- Siri NL edit interpret ✅
- Alt text ✅ (the generative half of `optimize-images`)
- Deploy-failure summary ✅
- `business-info` → conversational collection → LocalBusiness JSON-LD
- `new-page` headline / short-copy generation (scaffold + a11y validation are Bucket 3)
- `seasonal` suggestions (date + business-type lookup is deterministic; the suggestion
  text is short FM generation)
- `design-interview` design-axis interpretation (the 0–1 axis math is deterministic)
- `photography` shot-list tips (business-type lookup is deterministic)

### Bucket 5 — PCC escalation (heavier generation)
Open-ended generation beyond the on-device ceiling but achievable on Private Cloud
Compute. Escalation is a runtime tier choice; the front-door is unchanged.

- `copy-edit` (whole-site critique + rewrites)
- `design-interview` (multi-turn brand conversation + palette/typography)
- `social-media` (strategy + brand-voice posts), `repurpose` (per-platform variants)
- `reputation` (review-response drafts)
- `animate` (motion-design direction; CSS syntax itself is deterministic)
- `i18n` content translation
- `convert` / `import` content cleanup (the parse/scrape is Bucket 3)
- Commerce tier/product **copy** (the scaffold is Bucket 3)

### Bucket 6 — Simplify or retire
Exceeds even PCC for reliable quality, or delivers little once the prose-orchestration is
gone. Cut or reduce to a deterministic core.

- `creative-canvas` — open-ended Three.js/P5 code-gen. **Retire** the open generator;
  optionally ship a small library of vetted preset effects (Bucket 3).
- `experiment` — A/B design + statistical reasoning. **Simplify** to deterministic stats
  (significance, lift) + templated suggestions; drop the open-ended hypothesis chat.
- `email` — provider recommendation. **Simplify** to a deterministic decision tree
  (it's a flowchart over business type/values, not generative work).

## 6. Sequencing — vertical slices

Migrate one user journey end-to-end at a time. Per slice: (1) make the logic a
deterministic tool (Swift hot-path or sidecar) or FM function; (2) expose it via FM Tool,
App Intent, and GUI over the one implementation; (3) delete that journey's `claude --print`
path. Claude Code stays alive only for un-migrated journeys until the final slice flips,
then `ClaudeAgent` is deleted. Within each slice, **tool before brain.**

Proposed slice order (each independently shippable):

1. **Edit text/attribute** — `apply_edit` stays in the sidecar (Bucket 2); this slice
   wires the FM/Siri/overlay front-doors over it. Mostly proven already (overlay + Siri NL
   edit ship today); the work is routing chat through `FoundationModelAssistant`.
2. **Create page/post** — Bucket 1 scaffolding + Bucket 4 short-copy. Self-contained.
3. **Add a feature (integrations)** — Bucket 3 wizard framework, proven on `contact` /
   `newsletter` / `booking`, then templated across the rest of the integration set.
4. **Deploy** — Bucket 3 `deploy` flow + the security gate change (§7) + Bucket 4 deploy
   summary (already done).
5. **Theme / design** — Bucket 3 `themes` apply + Bucket 5 `design-interview` on PCC.
6. **Content help** — Bucket 5 `copy-edit`, `social-media`, `repurpose`.
7. **Cleanup** — retire Bucket 6 skills, delete `ClaudeAgent`, remove `--plugin-dir`
   wiring and the `claude` binary expectation, convert the plugin repo (§9).

## 7. Security gate change

CLAUDE.md's invariant — "the app cannot bypass plugin security hooks" — is today enforced
by the plugin's `PreToolUse` hook running `pre-deploy-check.sh`. With Claude Code gone, the
app runs that script (PII/token/third-party-script/Keystatic-route scans) **directly** as a
deterministic gate before every deploy, surfacing failures rather than allowing override.
This is *stronger*: a non-LLM gate can't be prompt-injected or talked out of running.

## 8. Risks & open questions

- **PCC availability & latency** for Bucket 5 — confirm the FoundationModels PCC tier is
  callable from both DevID and MAS builds and that quality clears the bar for `copy-edit` /
  `design-interview` before depending on it. The doc assumes Apple ships this; validate.
- **On-device context ceiling (~4K).** `copy-edit` over a whole site may exceed even PCC
  context — may need deterministic chunking (per-page) before generation.
- **MAS convergence.** Chat/Sparkle/`gh` are currently compiled out of MAS. Full removal +
  Apple-only AI makes MAS the natural primary target; the two build targets should
  re-converge on capability. Track as a consequence, not a separate decision.
- **Feature parity bar for "retire" (Bucket 6).** Confirm `creative-canvas` /
  open-ended `experiment` have low enough usage to drop without user pain.

## 9. End-state: what gets deleted

- `ClaudeAgent.swift` and the `claude --print` spawn path.
- `--plugin-dir` wiring in `buildArguments()`; the `claude` binary expectation.
- The plugin's **skill markdown** (the prose) and its `hooks.json` Claude hook.
- The plugin repo's deterministic guts are **absorbed, not deleted**: hot paths → Swift
  (Bucket 1), JS-ecosystem pieces → Node sidecar that runs **in the container** (Bucket 2;
  #59/#66/#69), `pre-deploy-check.sh` → direct app-run gate (§7).
- With all JS in-guest, the embedded **host** Node + JIT re-sign apparatus retires (#70):
  the sidecar is built into the OCI image (#62), not bundled into the app, so
  `copy-plugin.sh`'s Claude-plugin packaging is replaced by image build + "bundle templates
  only." The two-repo coordination model (paired PRs for MCP schema) ends; the app owns the
  sidecar.

## 10. Phasing summary

| Phase | Slices | Outcome |
|---|---|---|
| **P1** | Slice 1–2 | Edit + create journeys are Claude-free; `apply_edit` port resolved. |
| **P2** | Slice 3–4 | Integrations + deploy are wizard/Intent-driven; security gate native. |
| **P3** | Slice 5–6 | Design + content help on FM/PCC. |
| **P4** | Slice 7 | Bucket 6 retired, `ClaudeAgent` deleted, plugin repo converted. Claude Code dependency gone. |
