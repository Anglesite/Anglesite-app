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

## Discovery (Task 1 output)

Probe performed 2026-06-18 in worktree `fix-234-search-empty-query`. Method: add the
schema macro to an existing type, run `xcodebuild -scheme Anglesite -configuration Debug
build`, capture metadata-processor diagnostics, revert, repeat for each member. Baseline
build was clean (`** BUILD SUCCEEDED **`) before any probe. All source changes were reverted
(`git diff Sources/` clean) after each probe.

### `__appSchemaIntent` introspectability confirmed

`AddPageIntent.__appSchemaIntent == "wordProcessor.createPage"` passes under
`@testable import AnglesiteIntents` via `swift test`. Tasks 2–8 can assert schema ids using
this form. The same pattern applies to `__appSchemaEntity` for entities.

### Required-member contract per schema member

| Schema member | Kind | Applied to | Required members (verbatim from metadata processor) | Return shape / notes |
|---|---|---|---|---|
| `wordProcessor.createPage` | `@AppIntent` | `AddPageIntent` | `@Parameter target` (page entity — type inferred from `WordProcessorPageEntity` schema label; see note A), `@Parameter template` (optional in practice; probe emitted "missing required" but the schema may accept nil — verify in Task 5) | App-defined params not in schema must be `Optional`; `name: String` and `route: String?` flagged. Metadata-processor errors: `Missing required parameter 'target'`, `Missing required parameter 'template'`, `Intent parameters must be optional when not defined by the AppSchemaIntent` (×2). |
| `wordProcessor.openPage` | `@AppIntent` | `PreviewSiteIntent` | `OpenIntent` conformance required (Swift compiler–level, not metadata processor). `OpenIntent` protocol: `associatedtype Value: AppValue; var target: Self.Value { get set }`. So `PreviewSiteIntent` must conform to `OpenIntent` with `Value = PageEntity` and provide a `var target: PageEntity { get set }` stored property. | Compiler error before metadata processor: `type 'PreviewSiteIntent' does not conform to protocol 'OpenIntent'`. `OpenIntent.perform()` has a default impl; `openAppWhenRun` auto-set to `true`. All existing app-defined params must be `Optional`. |
| `wordProcessor.addImageToPage` | `@AppIntent` | `EditContentIntent` | `@Parameter image` (image asset — type not given by processor; schema label is `AddImageToWordProcessorPageIntent` — see note A), `@Parameter target` (page entity). App-defined `element: ElementEntity` and `instruction: String` flagged as must-be-optional. | Metadata-processor errors: `Missing required parameter 'image'`, `Missing required parameter 'target'`, `Intent parameters must be optional when not defined by the AppSchemaIntent` (×2). **Decision gate (Task 8):** `EditContentIntent` is NL-instruction–based; the schema wants an image asset + page target — a poor fit. Likely deferred. |
| `wordProcessor.page` | `@AppEntity` | `PageEntity` | `@Property pageIndex` (type not given; likely `Int` — integer page index in document), `@Property document` (type: a `WordProcessorDocumentEntity`-schema–conforming entity — i.e. whatever type conforms to `.wordProcessor.document` in the app, which will be `SiteEntity` after Task 3). Fixit verbatim: `var document: <#WordProcessorDocumentEntity#>`. | Metadata-processor errors: `Missing required property 'pageIndex'`, `Missing required property 'document'`. Warning: `The property 'typeDisplayRepresentation' should not be overridden in an AppEntity that conforms to a schema` (warning — do not override `typeDisplayRepresentation` on schema entities). |
| `wordProcessor.document` | `@AppEntity` | `SiteEntity` | `@Property modificationDate` (likely `Date`), `@Property name` (likely `String`), `@Property creationDate` (likely `Date`). | Metadata-processor errors: `Missing required property 'modificationDate'`, `Missing required property 'name'`, `Missing required property 'creationDate'`. Warning: do not override `typeDisplayRepresentation`. |
| `wordProcessor.template` | `@AppEntity` | `_TemplateEntityProbe` (scratch) | `@Property name` (likely `String`). | Metadata-processor error: `Missing required property 'name'`. Warning: do not override `typeDisplayRepresentation`. Only one required property — simpler than document. |

**Note A — parameter types:** The metadata processor names the required parameter/property
by key (e.g. `target`, `image`, `pageIndex`) but does not emit the Swift type in the error
message. The SDK schema labels (`WordProcessorPageEntity`, `WordProcessorDocumentEntity`) in
the fixit for `document` confirm the entity cross-reference shape. For intent parameters,
the types must be inferred from schema-label intent names and `OpenIntent` protocol
inspection:
- `target` on `createPage`: the page being created — type `PageEntity` (the app's
  `.wordProcessor.page`-conforming entity).
- `template` on `createPage`: the template to use — type should be the app's
  `.wordProcessor.template`-conforming entity (or `TemplateEntity` once Task 4 decides).
  Likely `Optional` since "create without template" is valid.
- `image` on `addImageToPage`: image asset — likely `IntentFile` (the AppIntents type for
  file payloads) or `URL`. Requires a Task 8 probe with a typed `@Parameter` to confirm.
- `target` on `addImageToPage`: the destination page — type `PageEntity`.
- `target` on `openPage`: per `OpenIntent` protocol, `var target: Self.Value { get set }`;
  `Value` must be the page entity, i.e. `PageEntity`.

### `typeDisplayRepresentation` constraint (all schema entities)

All three entity probes (`page`, `document`, `template`) produced this warning:
`The property 'typeDisplayRepresentation' should not be overridden in an AppEntity that
conforms to a schema`. This is a metadata-processor warning, not an error — but Tasks 2–4
should follow it: do not declare `static var typeDisplayRepresentation` on any
schema-conforming entity. The schema provides this automatically.

### Key decision implications for later tasks

- **Task 2 (`page`):** Add `@Property var pageIndex: Int` and `@Property var document:
  SiteEntity` (after Task 3 makes `SiteEntity` the `document` schema entity). Remove or
  stop overriding `typeDisplayRepresentation`. The `pageIndex` will be synthetic (derive
  from sort order or set to 0 — pages don't have a canonical integer index in Anglesite).
- **Task 3 (`document`):** Add `@Property var name: String`, `@Property var creationDate:
  Date`, `@Property var modificationDate: Date`. `SiteEntity` has `displayName` but not a
  `name` property — add one (alias of `displayName`). Dates require `SiteStore.Site` to
  expose them (or derive from filesystem metadata).
- **Task 4 (`template`):** Only `@Property var name: String` required. Minimal surface —
  worthwhile to surface if a `TemplateEntity` is created.
- **Task 5 (`createPage`):** Add `@Parameter var target: PageEntity?` and `@Parameter var
  template: TemplateEntity?` (both Optional since the schema may accept nil); make
  `name: String` and `route: String?` `Optional`. **Risk:** making `name` optional changes
  the required-parameter dialog.
- **Task 6 (`openPage`):** `PreviewSiteIntent` must conform to `OpenIntent` and rename
  `page` to `target` (or add `target` as an alias). The `OpenIntent` default `perform()` is
  a no-op that opens the app; override it with the existing routing logic. **Risk:** the
  `OpenIntent` protocol may impose additional constraints — probe carefully.
- **Task 7 (`AddPostIntent` / `createPage`):** Two intents on one schema id — unknown
  whether the metadata processor or assistant tolerates this. Probe in Task 7 before
  committing.
- **Task 8 (`addImageToPage`):** Decision gate verdict: likely **deferred** —
  `EditContentIntent` is NL-instruction–based, not image-asset–targeted.

## Packaging

One worktree, one PR re-scoping/closing #235, with the spike doc already landed separately.
Commits sequenced: (1) discovery-probe findings appended to this spec, (2) entity
conformances, (3) intent conformances, (4) tests. Reframe #164 D.3 to the conformance test
(comment on the issue); add the Siri end-to-end check to #166.

## createPage.target dependency probe

Probe performed 2026-06-18 in worktree `fix-234-search-empty-query`. Method: add
`@available(macOS 26.0, *)` + `@AppIntent(schema: .wordProcessor.createPage)` to
`AddPageIntent`, add `@Parameter(title: "Target") public var target: PageEntity?` (plain
existing `PageEntity` — no schema conformance added), make `name: String` optional to
suppress the unrelated non-schema-param error. Built with
`xcodebuild -scheme Anglesite -configuration Debug build` and captured metadata-processor
diagnostics. All source changes were reverted after (`git diff Sources/` = 0 lines).

### Verbatim diagnostics

```
error: Required AppSchemaIntent parameter 'target' must not be optional
error: Parameter 'target' does not match required AppSchemaIntent type 'WordProcessorDocumentEntity'
error: Missing required parameter 'template' from AppSchemaIntent 'wordProcessor.createPage'
error: Intent parameters must be optional when not defined by the AppSchemaIntent
```

### Verdict: **TARGET REQUIRES .document CONFORMANCE (not .page)**

The metadata processor rejects `PageEntity` for `target` with:
`Parameter 'target' does not match required AppSchemaIntent type 'WordProcessorDocumentEntity'`.

This means **`createPage.target` is the destination *document* (the container), not the
created page** — semantically "create a page in this document". The required type is
`WordProcessorDocumentEntity`, i.e. the app's `.wordProcessor.document`-conforming entity.
In Anglesite's model that will be `SiteEntity` (once Task 3 adds `@AppEntity(schema:
.wordProcessor.document)` conformance). A plain `PageEntity` (not schema-conforming) is
explicitly rejected, and even a `.wordProcessor.page`-conforming entity would not satisfy
this parameter.

Additional constraint: `target` must be **non-optional** (the processor errors "must not be
optional").

### Impact on Task 5 (`AddPageIntent` schema adoption)

- `target` must be `var target: SiteEntity` (non-optional), not `PageEntity`. This means
  **Task 3 (`SiteEntity → .wordProcessor.document`) must land before Task 5**.
- The existing `site: SiteEntity` parameter becomes `target: SiteEntity` (rename + schema
  adoption, same type).
- `template` is still missing (the processor flagged it); its type is the app's
  `.wordProcessor.template`-conforming entity — defer until Task 4 confirms `TemplateEntity`
  is worth adding, or omit if the schema accepts a missing optional template.
- Prior Note A in the table above was incorrect: it inferred `target` = page entity. The
  correct mapping is `target` = document entity.
