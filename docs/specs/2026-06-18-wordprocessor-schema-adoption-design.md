# Design — Adopt `AppSchema.WordProcessor` for Anglesite's content-authoring intents

**Issue:** [#235](https://github.com/Anglesite/Anglesite-app/issues/235) (re-scoped; parent [#135](https://github.com/Anglesite/Anglesite-app/issues/135), Phase D)
**Date:** 2026-06-18
**Depends on:** the SDK-verification spike — [`2026-06-18-assistant-schema-exposure-spike.md`](2026-06-18-assistant-schema-exposure-spike.md); D.1 audit ([`2026-06-17-d1-intent-mcp-readiness-audit.md`](2026-06-17-d1-intent-mcp-readiness-audit.md)); D.2 ([`2026-06-17-d2-mcp-tool-descriptors-design.md`](2026-06-17-d2-mcp-tool-descriptors-design.md))
**Touches:** [#164](https://github.com/Anglesite/Anglesite-app/issues/164) (D.3 — reframed), [#166](https://github.com/Anglesite/Anglesite-app/issues/166) (D.5 smoke), [#239](https://github.com/Anglesite/Anglesite-app/issues/239) / [#236](https://github.com/Anglesite/Anglesite-app/issues/236) (where confirmation/diagnostics metadata belongs)

## Goal

Make Anglesite's content-authoring intents and entities **first-class to macOS 27 system
AI** by conforming them to Apple's current `AppSchema.WordProcessor` schema. Today these
intents reach Siri/Shortcuts/Spotlight as free-text-titled actions; schema conformance
makes Apple Intelligence (and the App-Intents-derived agent surface) understand them
*semantically* — "create a page", "open a page", "add an image to a page" — by matching a
shape Apple's models already know.

### Confirmed scope (brainstorm decisions)

- **The win is Siri / Apple Intelligence comprehension**, not a new MCP transport. The
  spike established that the MCP tool surface is already auto-derived from intent schema
  (D.1/D.2); there is no imperative MCP registration API to build. This design does not add
  MCP plumbing — it makes the authoring intents schema-typed for system AI.
- **Wide slice:** adopt the full authoring surface in one design — document/template/page
  entities and the `add*ToPage` content-insertion intents — not just the narrow
  create/open trio.

## Verified foundation (from the spike — facts, not assumptions)

1. **Use `AppSchema`, not `AssistantSchemas`.** The `AssistantSchemas.*` family (the
   `@AssistantIntent(schema:)` path, macOS 15) is **deprecated in macOS 27** (89
   deprecation markers; the WordProcessor accessor is explicitly `@available(*,
   deprecated)`). The current family is `AppSchema.*`, adopted via `@AppIntent(schema:)` /
   `@AppEntity(schema:)`. Apple's *docs* still describe the deprecated family — do not
   follow them verbatim.
2. **The macro is a lightweight tag.** A compile-probe of
   `@AppIntent(schema: .wordProcessor.createPage)` on an empty intent **compiled clean** —
   the macro only emits `static let __appSchemaIntent = "wordProcessor.createPage"` and an
   `AssistantSchemaIntent` conformance. `swiftc` does **not** enforce required `@Parameter`
   members.
3. **Conformance is validated by the AppIntents metadata processor** during a real
   `xcodebuild` of the app target (and by the assistant at runtime) — *not* by `swift
   test` / `swiftc -typecheck`. So required-shape correctness must be proven by building
   the `.app`, reading the processor diagnostics, then matching the shape.

## The full WordProcessor surface (verified from the SDK interface)

**Intents** (`.wordProcessor.<member>`): `create`, `open`, `createPage`, `openPage`,
`addTextBoxToPage`, `addImageToPage`, `addAudioToPage`, `addVideoToPage`,
`addWebVideoToPage`.
**Entities** (`.wordProcessor.<member>`): `document`, `template`, `page`.

## Mapping to Anglesite

| Anglesite type | → `AppSchema.WordProcessor` | Confidence / notes |
|---|---|---|
| `AddPageIntent` | `@AppIntent(schema: .wordProcessor.createPage)` | High — direct |
| `PreviewSiteIntent` (page-level) | `.wordProcessor.openPage` | High — opens a specific page |
| `PageEntity` | `@AppEntity(schema: .wordProcessor.page)` | High — direct |
| `SiteEntity` | `.wordProcessor.document` | Medium — a site is the "document" container; verify required members fit |
| Anglesite Template (`Resources/Template/`) | `.wordProcessor.template` | Medium — conceptual fit; only if a `TemplateEntity` is worth surfacing |
| `EditContentIntent` (image insert path) | `.wordProcessor.addImageToPage` | Medium — `EditContentIntent` is broader than image-insert; may need splitting or mapping only the matching sub-action |
| `AddPostIntent` | `.wordProcessor.createPage` (a post is a page) | Medium — decide whether post≈page or leave plain |
| `create` / `addText/Audio/Video/WebVideoToPage` | — | Evaluate per required-shape; adopt where an Anglesite action genuinely matches, else leave out (no force-fit) |
| `DeploySiteIntent`, `BackupSiteIntent`, `AuditSiteIntent` | **none** | Correct — no domain analog; stay plain `AppIntent`, still Siri/Shortcuts/Spotlight-reachable |

## Approach — discovery-first, because the contract isn't in the SDK

The exact required `@Parameter` members per schema are enforced by the metadata processor,
not the type system, and Apple's published docs cover the deprecated family. So the design
is **probe → map → adopt**, per schema member:

1. **Discovery probe (first task).** Add `@AppIntent(schema: .wordProcessor.createPage)` to
   `AddPageIntent`, run a full `xcodebuild` of the `Anglesite` target, and capture the
   metadata-processor diagnostics. Those diagnostics are the authoritative list of required
   members (parameter names/types, return shape) for that schema. Record them in this spec
   as they're discovered.
2. **Map + refactor.** Adjust the intent's `@Parameter`s / return type to satisfy the
   schema, preserving today's behavior and dialog. Re-resolution is by entity `id` (per
   D.2's structural fact), so additive parameter changes are Shortcuts-safe.
3. **Repeat per member** across the wide surface (entities first — `page`, `document`,
   `template` — since intents reference them, then the intents).

## Testing

- **Unit (`AnglesiteIntents`, Swift Testing):** assert each adopted type carries the
  expected schema id — the macro-generated `__appSchemaIntent` / `__appSchemaEntity`
  member is introspectable, mirroring the existing schema-seam test style. This is the
  honest reframing of #164 D.3: there is no `register()` to call, so D.3 becomes "test that
  the intents declare the expected schema conformance."
- **Behavior preserved:** existing `ContentOperationsOverride` / `ContentGraphOverride`
  seam tests must stay green — schema adoption must not change `perform()` semantics.
- **Metadata-processor gate:** a clean `xcodebuild` of both schemes with zero
  schema-conformance diagnostics is the build-time proof of correct conformance.
- **End-to-end (deferred to D.5 #166):** real Siri/Apple-Intelligence invocation of
  "create a page" / "open a page" can only be verified on a macOS 27 device — add to the
  #166 manual smoke checklist.

## Build / verification gates (per CLAUDE.md)

- **Both schemes via `xcodebuild`** (`Anglesite` + `AnglesiteMAS`), not just `swift test`
  — only the app build runs the metadata processor that validates schema conformance, and
  the `.app` must link with the changed derived metadata.
- Worktree prerequisites: `xcodegen generate` first; set `ANGLESITE_PLUGIN_SRC` to the
  real plugin checkout.

## Risks

- **Required-shape mismatch forces behavior change.** If a schema mandates a parameter
  Anglesite's intent can't naturally supply, adopting it could distort the intent's UX.
  Mitigation: the probe surfaces this *before* committing; if a member's required shape
  fights Anglesite's model, **leave that intent plain** rather than contort it. Adoption is
  opt-in per intent.
- **Wide slice = larger refactor before anything ships.** Mitigation: sequence
  entities-then-intents and keep each schema member's adoption in its own commit so a
  problematic member can be dropped without unwinding the rest.
- **Docs describe the deprecated family.** Mitigation: trust the metadata-processor
  diagnostics + the `AppSchema` SDK interface over developer.apple.com prose.
- **MAS metadata extraction parity.** The sandboxed target must also pass the processor;
  verify both, since `#if ANGLESITE_MAS` gating could in principle diverge the intent set.

## Out of scope

- Any imperative MCP registration / `AnglesiteMCPRegistration` type — SDK-confirmed
  impossible (spike).
- Operation-metadata / confirmation-invariant registry (side-effect level, confirmation,
  cancellability) — belongs to **#239** (confirmation gates) and **#236** (diagnostics),
  not here.
- `Browser` schema for preview — weak fit; `openPage` covers page preview.
- Deploy/backup/audit schema typing — no domain analog.

## Packaging

One worktree, one PR re-scoping/closing #235, with the spike doc already landed separately.
Commits sequenced: (1) discovery-probe findings appended to this spec, (2) entity
conformances, (3) intent conformances, (4) tests. Reframe #164 D.3 to the conformance test
(comment on the issue); add the Siri end-to-end check to #166.
