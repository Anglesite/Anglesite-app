# Siri natural-language edits: interpretation + dry-run diff confirmation (#251) — design

**Status:** approved (brainstorming) · **Date:** 2026-06-19 · **Branch:** `worktree-251-siri-edit-diff`

## Goal

Turn the Siri content-edit confirmation (shipped as a human-readable *summary* in #239/PR #250)
into a real, reviewed **before → after change**. A spoken instruction like "make it shorter" or
"change the color to teal" is interpreted on-device into a concrete structured edit, previewed
against the actual source via a non-mutating dry-run, and applied only after the user confirms.

This supersedes the original #251 framing ("structured diff + decline-path test") with a larger,
agreed scope: the Siri path (`EditContentIntent`) currently emits a free-form `apply-instruction`
op the plugin cannot interpret. We replace that with **app-side natural-language interpretation**
(Foundation Models) that emits concrete plugin ops, and we add the plugin support those ops need.

## Scope (agreed)

In scope — three edit kinds, end to end:

- **Text** — innerText edits ("make it shorter", "fix the typo") → `replace-text`.
- **Attribute** — attribute edits ("change the alt text to …") → `replace-attr`.
- **Style** — CSS edits ("make it teal", "make it bigger") → a **new `edit-style` op**.

Plus:

- An app-side Foundation Models **interpreter** that classifies the instruction and produces the op.
- A plugin **`dry_run`** mode on `apply_edit` that computes before/after without writing.
- The before/after **confirmation rendering**.
- The **decline-path test** (#251 part 2), made into a real test rather than by-inspection.
- Paired plugin release + app bundled-plugin pointer bump.

Explicitly out of scope (documented follow-ups):

- CSS targets other than the owning component's scoped `<style>` — global stylesheets, Tailwind
  class rewriting, inline `style=""`. v1 uses scoped `<style>` only (see CSS resolution below).
- The WKWebView click-to-edit overlay path (routes directly through `EditRouter`, already
  structured, not a Siri/NL surface).
- Any edit-mutating intent beyond `EditContentIntent`.
- A machines-without-Apple-Intelligence interpretation fallback (no on-device model → no NL edit;
  see fallback below).

## Architecture & data flow

The pipeline becomes two-phase — **interpret → preview/confirm → apply** — with NL interpretation
in the app and a non-mutating dry-run sourcing the diff.

```
EditContentIntent.perform()
  ├─ decode selector ──(fails)──▶ editInvalidSelector dialog          [no prompt, no route]
  │
  ├─ INTERPRET (app, Foundation Models)
  │    instruction + element context ──▶ @Generable EditInterpretation
  │      { kind: text | attribute | style, payload, summary }
  │    └─(FM unavailable / can't interpret)──▶ graceful dialog, no route
  │
  ├─ DRY-RUN (plugin apply_edit, dry_run:true)
  │    op + value ──▶ locate source, compute before/after WITHOUT writing
  │    └─(no-match / ambiguous / dynamic-expression)──▶ failed/ambiguous dialog, no route
  │
  ├─ CONFIRM  requestConfirmation(dialog: before→after summary)
  │    └─(decline → throws)──▶ exits before apply             [working tree unchanged]
  │
  └─ APPLY (plugin apply_edit, dry_run:false)  ── same op + value ──▶ commit (unchanged downstream)
```

Key properties:

- The app classifies every instruction into one concrete op. The free-form `apply-instruction`
  op is **retired** — the app never emits it again. (`EditMessage.Op.applyInstruction` is removed;
  its plugin-side absence is no longer a gap.)
- `dry_run` is the **single source** of the before/after shown in the confirmation. The app cannot
  know an element's current attribute/style value from source on its own; the plugin locates it.
- The confirmation gate from #239/PR #250 is structurally **unchanged** — it receives a richer
  `before → after` string instead of a bare summary. The decline → no-write property is preserved.
- Two plugin round-trips per edit (dry-run, then apply). Acceptable: the gate already implies a
  human-in-the-loop pause between them, and the dry-run is read-only.

## Components

### 1. App — `EditInstructionInterpreter` (`AnglesiteCore`)

Thin Foundation Models call, with the testable logic separated out (the `TokenOnboarding`
pattern — hosted app/FM code can't run on CI, so the parsing/mapping that can is isolated).

- Input: the spoken `instruction` plus element context the app already holds from `ElementEntity`
  / its stored `ElementInfo` — `tag`, current `textContent`, `classes`, `id`, `pagePath`, ancestors.
- Foundation Models **guided generation** populates a `@Generable` result:

  ```swift
  @Generable struct EditInterpretation {
      @Guide(description: "What kind of change to make")
      var kind: EditKind                 // text | attribute | style
      // payload fields guided per kind:
      //   text:      newText: String
      //   attribute: attributeName: String, attributeValue: String
      //   style:     styleProperty: String, styleValue: String
      @Guide(description: "One-line human phrasing of the change for confirmation")
      var summary: String
  }
  ```

- Maps `EditKind` → concrete plugin op + `value`:
  - `text` → `replace-text`, value = `.string(newText)`
  - `attribute` → `replace-attr`, value = `{ name, value }`
  - `style` → `edit-style`, value = `{ property, value }`
- The live FM invocation sits behind an `EditInterpreting` protocol so unit tests inject a fake
  returning canned `EditInterpretation`s. The op-mapping + payload validation is **pure** and runs
  on CI; the live model call is exercised only in hosted/manual smoke.
- **FM-unavailable fallback:** Foundation Models requires Apple Intelligence (capable hardware,
  macOS 26+, behind the `#if compiler(>=6.4)` toolchain gate). When unavailable, `perform()`
  returns a clear dialog — *"Editing by voice needs Apple Intelligence, which isn't available
  here."* — and routes nothing. Respects the known mid-stream-cancel crash constraint: no cancel
  of a live FM `streamResponse`.

### 2. App — `EditContentIntent.perform()` rewrite

Replaces the single `applyEdit(op: applyInstruction, …)` call with the interpret → dry-run →
confirm → apply sequence above. The bridge (`IntentEditBridge`) gains a `dry_run` parameter so the
intent can request a preview and an apply through the same seam. Cancellation handling
(`reply.message == "canceled"`) is unchanged.

### 3. App — `ContentDialogs.editConfirmation(...)` overload

New overload taking `EditInterpretation` + the dry-run preview, producing **spoken-friendly**
phrasing per kind (Siri reads the dialog aloud — a multi-line diff is useless by voice):

- text → *"Change the heading from "Welcome to my site" to "Welcome to my studio" on /about/?"*
- attribute → *"Change the image's alt text from "logo" to "Studio logo" on /about/?"*
- style → *"Set color to teal on the heading on /about/?"* (resulting change, not before→after)

Long before/after text is **truncated with an ellipsis** in the spoken summary. All phrasing
helpers stay pure and unit-tested, alongside the existing `editApplied` / `editFailed` / etc.

### 4. Plugin — `apply_edit` `dry_run` flag (paired PR)

`server/apply-edit-schema.mjs`, `apply-edit-dispatcher.mjs`. The dispatcher already computes
`source` (before) and `next` (after) in memory before writing.

- Add `dry_run: z.boolean().optional()` to the input shape.
- When `dry_run` is true: skip `atomicWrite` and the `onApplied` history commit; return a new
  `anglesite:edit-preview` response: `{ id, file, range, op, before, after }`.
- `before`/`after` are the **spliced region plus a small surrounding context window** (not whole
  files) — legible diffs, bounded payload.
- Refusals (`no-match`, `ambiguous`, `dynamic-expression`, `write-failed`, …) return exactly as
  today, so the app's dry-run gets the same failure taxonomy and surfaces it *before* prompting.

### 5. Plugin — new `edit-style` op (paired PR)

- Add `"edit-style"` to the op enum (`editOps`); value is `{ property, value }`.
- **CSS resolution by component encapsulation:** sites are authored as Astro components (the
  web-component equivalent) co-locating HTML + scoped `<style>` + JS. So a style edit lands
  deterministically in the **owning component's scoped `<style>`** — encapsulation bounds the
  location; no multi-file heuristic hunt.
  1. Resolve the element to its owning `.astro` source file (the locating the patcher already does).
  2. Merge a rule for the element into that file's `<style>` block (create the block if absent).
  3. Target selector: the element's existing `id` or a class; if it has **neither**, add a minimal
     **marker class** (e.g. `ang-<short-hash>`) to the element's opening tag and target that.
  4. before/after diff is the `<style>` region (+ the tag edit when a marker class is added).
- Authoring guideline (template): prefer component-scoped structure so style resolution stays
  deterministic. Documented, not enforced by this PR.

### 6. Versioning / release

- Bump `package.json` + `.claude-plugin/plugin.json` to the same new version; tag a release
  (the release workflow verifies version == tag and packs the plugin zip).
- App bumps its bundled-plugin pointer (the `scripts/copy-plugin.sh` source / pinned tag) per the
  paired-PR convention in CLAUDE.md.

## Data flow summary

`(element, instruction)` → decode selector → **interpret** (FM → op + value) → **dry-run** (plugin
locates source, returns before/after, no write) → **confirm** (before→after dialog) →
**[confirm]** apply (same op + value) → reply → dialog (with `ChatModel.recordEdit` firing on
commit, as today) · **[decline]** throw before apply → zero apply calls, working tree unchanged ·
**[FM unavailable / bad selector / dry-run refusal]** respective dialog, no apply.

## Testing

### App (`AnglesiteCoreTests` / `AnglesiteIntentsTests`, Swift Testing)

1. **interpreter op-mapping** — inject a fake `EditInterpreting`; assert each `EditKind` maps to
   the correct op + value, and malformed/empty payloads are rejected. (Pure, CI.)
2. **`editConfirmation` overload** — phrasing + truncation per kind.
3. **`perform()` flow** — extend the existing `RecordingRouter` + `IntentEditBridgeOverride.scoped`
   harness so the bridge records **dry-run vs apply** calls separately; assert the happy path does
   one dry-run then one apply with matching op/value.
4. **decline-path (headline safety property)** — extract the confirmation outcome behind an
   injectable `ConfirmationDeciding` seam (defaulting to the real `requestConfirmation`). Drive it
   to **declined** and assert the bridge saw the **dry-run call but zero apply calls** — proving a
   decline never writes. If macOS 26's **App Intents Testing** exposes a real confirmation harness,
   prefer it and drop the seam; the implementer confirms which and the plan records the choice.
5. **FM-unavailable** — interpreter reports unavailable → `perform()` returns the graceful dialog,
   zero router calls.

### Plugin (`vitest`)

1. **`dry_run` is read-only** — `dry_run:true` returns `edit-preview` with before/after **and the
   target file is byte-identical on disk afterward** (the critical assertion).
2. **`edit-style`** — creates/merges a scoped `<style>` rule; adds a marker class only when the
   element lacks id/class; before/after diff is the `<style>` region.
3. **refusals under `dry_run`** — `no-match` / `ambiguous` still return correctly with `dry_run:true`.

## Paired-PR sequencing

1. **Plugin PR** adds `dry_run` + `edit-style`, tests, version bump; tag + release.
2. **App PR** consumes them: interpreter, `perform()` rewrite, confirmation overload, decline test;
   bump the bundled-plugin pointer.

The app code can be written against the new op names immediately (they're just strings), but the
e2e `AppliesEditEndToEndTests` / `MCPClientHTTPEndToEndTests` need the released plugin checked out
(`ANGLESITE_PLUGIN_PATH`).

## Acceptance-criteria mapping

| Criterion | Covered by |
|---|---|
| Siri NL edit produces a real reviewed before→after change | interpret → dry-run → confirm flow |
| Text / attribute / style instructions all supported | §1 interpreter + §4/§5 plugin ops |
| Confirmation shows the actual change, voice-friendly | §3 `editConfirmation` overload |
| Decline leaves the working tree untouched (tested) | §Testing app #4 (injectable decline seam) |
| Dry-run never writes (tested) | §Testing plugin #1 (byte-identical file assertion) |
| Style edits land deterministically | §5 component-scoped `<style>` + marker class |
| No NL model → graceful, no mutation | §1 FM-unavailable fallback + §Testing app #5 |

## Risks / notes

- **FM quality / misclassification.** The interpreter can pick the wrong kind or value
  ("make it shorter" → height vs text). The confirmation is the safety net: the user sees exactly
  what will change before it applies. We do not auto-apply.
- **Scoped-`<style>` assumption.** v1 only edits the owning component's scoped block. Sites that
  style via global CSS or Tailwind won't get the edit where they expect — `edit-style` should
  refuse clearly (not silently add a conflicting scoped rule) when it can't form a confident
  scoped target. Other CSS targets are explicit follow-ups.
- **`#if compiler(>=6.4)` gate.** Foundation Models symbols and `LongRunningIntent`/
  `CancellableIntent` are macOS 26+; interpreter code and conformances stay behind the existing
  gate. The pure op-mapping/dialog code stays outside it so CI keeps covering it.
- **Two round-trips.** Dry-run then apply doubles plugin calls per edit; acceptable given the
  human pause and the read-only dry-run. If latency bites, a future optimization can let the apply
  reuse the dry-run's resolved range.
- **Marker-class churn.** Adding `ang-<hash>` classes mutates markup on first style edit of an
  un-classed element. Acceptable and diff-visible; the confirmation shows the tag change too.
