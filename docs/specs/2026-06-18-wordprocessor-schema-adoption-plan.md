# WordProcessor Schema Adoption — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conform Anglesite's content-authoring intents and entities to Apple's current `AppSchema.WordProcessor` schema so they are first-class to macOS 27 Siri / Apple Intelligence.

**Architecture:** Each intent/entity gains a `@AppIntent(schema: .wordProcessor.X)` / `@AppEntity(schema: .wordProcessor.X)` macro and is refactored to satisfy that schema's required members. The required members are not in the SDK type system — they are enforced by the AppIntents *metadata processor* at `xcodebuild` time — so Task 1 discovers the contract empirically and records it in the design doc; later tasks consume that record. `perform()` behavior and dialog are preserved throughout (re-resolution is by entity `id`, so parameter additions are Shortcuts-safe).

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), AppIntents framework, Swift Testing, XcodeGen, `xcodebuild`.

## Global Constraints

- **Toolchain:** Xcode 27+ / Swift 6.4. Target macOS 27.
- **Use `AppSchema`, NOT `AssistantSchemas`.** The `AssistantSchemas.*` / `@AssistantIntent(schema:)` family is deprecated in macOS 27. Adopt only `@AppIntent(schema:)` / `@AppEntity(schema:)` against `AppSchema.WordProcessor`.
- **Verify with `xcodebuild`, not just `swift test`.** Only the app build runs the metadata processor that validates schema conformance. Build **both** schemes: `Anglesite` and `AnglesiteMAS`.
- **Worktree prerequisites (run once, Task 1):** `xcodegen generate` first (the `.xcodeproj` is gitignored); export `ANGLESITE_PLUGIN_SRC=<path to the real github.com/Anglesite/anglesite checkout>` so `copy-plugin.sh` resolves.
- **Adoption is opt-in per intent.** If a schema's required shape fights Anglesite's model, leave that intent plain rather than contort it — record the decision in the design doc.
- **Frequent commits**; one schema member's adoption per commit so a problematic member can be dropped without unwinding the rest.
- Commit-message trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

**Reference (verified) — the `AppSchema.WordProcessor` surface:**
- Intents (`.wordProcessor.<m>`): `create`, `open`, `createPage`, `openPage`, `addTextBoxToPage`, `addImageToPage`, `addAudioToPage`, `addVideoToPage`, `addWebVideoToPage`.
- Entities (`.wordProcessor.<m>`): `document`, `template`, `page`.
- The `@AppIntent(schema:)` macro generates `static let __appSchemaIntent = "wordProcessor.<m>"` and an `AssistantSchemaIntent` conformance; `@AppEntity(schema:)` generates `__appSchemaEntity` and an `AssistantSchemaEntity` conformance.

**Current authoring types (files):**
- `Sources/AnglesiteIntents/ContentIntents.swift` — `AddPageIntent`, `AddPostIntent`, `PreviewSiteIntent`, `SearchContentIntent`, `SiteStatusIntent`.
- `Sources/AnglesiteIntents/EditContentIntent.swift` — `EditContentIntent`.
- `Sources/AnglesiteIntents/ContentEntities.swift` — `PageEntity`, `PostEntity`, `ImageEntity` (confirm exact file in Task 1).
- `Sources/AnglesiteIntents/SiteEntity.swift` — `SiteEntity`.
- Tests: `Tests/AnglesiteIntentsTests/` (Swift Testing).

---

### Task 1: Discovery probe — pin the required-member contract

**Goal:** Learn exactly what `AppSchema.WordProcessor.createPage` requires, and confirm the macro-generated member is test-introspectable, before refactoring anything.

**Files:**
- Modify (temporary): `Sources/AnglesiteIntents/ContentIntents.swift` — `AddPageIntent`.
- Modify (record findings): `docs/specs/2026-06-18-wordprocessor-schema-adoption-design.md` — add a `## Discovery (Task 1 output)` section.

**Interfaces:**
- Produces: a documented table — for each adopted schema member (`createPage`, `openPage`, `page`, `document`, `template`, `addImageToPage`), its required `@Parameter` names/types and required return shape — that Tasks 2–8 consume verbatim.

- [ ] **Step 1: Worktree prep**

```bash
cd <worktree>
export ANGLESITE_PLUGIN_SRC=<path to github.com/Anglesite/anglesite>
xcodegen generate
```
Expected: `Created project at Anglesite.xcodeproj`.

- [ ] **Step 2: Establish a clean baseline build**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. (If it fails, fix the environment before proceeding — do not attribute later schema diagnostics to a pre-existing break.)

- [ ] **Step 3: Add ONLY the schema macro to `AddPageIntent` (no parameter changes yet)**

In `ContentIntents.swift`, annotate the `AddPageIntent` declaration:
```swift
@available(macOS 26.0, *)
@AppIntent(schema: .wordProcessor.createPage)
public struct AddPageIntent: AppIntent {
    // unchanged body
}
```

- [ ] **Step 4: Build and capture the metadata-processor diagnostics**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 \
  | grep -iE "schema|appintents.*metadata|required|wordProcessor|createPage" | tee /tmp/schema-probe.txt
```
Expected: either `BUILD SUCCEEDED` (the current shape already satisfies the schema) **or** metadata-processor errors/warnings naming the required members the intent is missing (e.g. "intent conforming to schema 'createPage' must have a parameter '<name>' of type '<type>'"). Capture the full text.

- [ ] **Step 5: Record the contract in the design doc**

Add a `## Discovery (Task 1 output)` section to the design doc transcribing, for `createPage`: the exact required parameter names + types and the required return type. Repeat Steps 3–4 transiently for `openPage`, `addImageToPage` (on `EditContentIntent`), and the entities `page` / `document` / `template` (using `@AppEntity(schema: .wordProcessor.X)` on the matching entity), recording each member's required shape. Then **revert all probe edits** (`git checkout -- Sources/`), leaving only the design-doc edit.

- [ ] **Step 6: Confirm the generated member is introspectable from tests**

Temporarily re-add the `createPage` macro to `AddPageIntent`, then in a scratch test confirm the schema id is readable under `@testable import`:
```swift
import Testing
@testable import AnglesiteIntents
@Test func probeSchemaIdReadable() {
    #expect(AddPageIntent.__appSchemaIntent == "wordProcessor.createPage")
}
```
Run: `swift test --package-path . --filter probeSchemaIdReadable`
Expected: PASS (proves Tasks 2–8 can assert schema ids). If `__appSchemaIntent` is not accessible, record the working introspection approach (e.g. an `is AssistantSchemaIntent` conformance check) in the design doc instead, and use that form in later tasks. Revert the scratch test.

- [ ] **Step 7: Commit the recorded contract**

```bash
git add docs/specs/2026-06-18-wordprocessor-schema-adoption-design.md
git commit -m "docs(intents): record WordProcessor schema required-member contract (#235)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Adopt `.wordProcessor.page` on `PageEntity`

Entities first — intents reference them. Consumes the `page` required-member row from the design doc's Discovery section.

**Files:**
- Modify: the file declaring `PageEntity` (confirm in Task 1; likely `Sources/AnglesiteIntents/ContentEntities.swift`).
- Test: `Tests/AnglesiteIntentsTests/SchemaConformanceTests.swift` (create).

**Interfaces:**
- Consumes: Discovery row for `.wordProcessor.page` (required `@Property` members).
- Produces: `PageEntity` carries `__appSchemaEntity == "wordProcessor.page"`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteIntentsTests/SchemaConformanceTests.swift`:
```swift
import Testing
@testable import AnglesiteIntents

@Suite struct SchemaConformanceTests {
    @Test func pageEntityCarriesWordProcessorPageSchema() {
        #expect(PageEntity.__appSchemaEntity == "wordProcessor.page")
    }
}
```
(If Task 1 recorded a different introspection form, use that form here and in all later schema tests.)

- [ ] **Step 2: Run the test — verify it fails**

Run: `swift test --package-path . --filter pageEntityCarriesWordProcessorPageSchema`
Expected: FAIL (no `__appSchemaEntity` member yet).

- [ ] **Step 3: Add the macro + satisfy required `@Property` members**

Annotate `PageEntity` with `@AppEntity(schema: .wordProcessor.page)` and add/rename only the `@Property` members the Discovery section lists as required (do not drop existing fields; additions are id-safe). Keep `displayRepresentation` and `id` unchanged.

- [ ] **Step 4: Run the schema test — verify it passes**

Run: `swift test --package-path . --filter pageEntityCarriesWordProcessorPageSchema`
Expected: PASS.

- [ ] **Step 5: Run the full intents suite — verify no regression**

Run: `swift test --package-path . --filter AnglesiteIntents`
Expected: all existing `PageEntity` round-trip / query tests still PASS.

- [ ] **Step 6: Build the app target — verify metadata processor accepts it**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`, no schema diagnostics.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(intents): conform PageEntity to AppSchema.wordProcessor.page (#235)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Adopt `.wordProcessor.document` on `SiteEntity`

Same shape as Task 2, for the document container. Consumes the `document` Discovery row.

**Files:**
- Modify: `Sources/AnglesiteIntents/SiteEntity.swift`.
- Test: `Tests/AnglesiteIntentsTests/SchemaConformanceTests.swift` (extend).

**Interfaces:**
- Consumes: Discovery row for `.wordProcessor.document`.
- Produces: `SiteEntity.__appSchemaEntity == "wordProcessor.document"`.

- [ ] **Step 1: Write the failing test** — add to `SchemaConformanceTests`:
```swift
@Test func siteEntityCarriesWordProcessorDocumentSchema() {
    #expect(SiteEntity.__appSchemaEntity == "wordProcessor.document")
}
```
- [ ] **Step 2: Run — verify it fails.** Run: `swift test --package-path . --filter siteEntityCarriesWordProcessorDocumentSchema` → FAIL.
- [ ] **Step 3: Add `@AppEntity(schema: .wordProcessor.document)` to `SiteEntity`** and satisfy its required `@Property` members per Discovery. **Decision gate:** if `document` mandates members `SiteEntity` cannot naturally provide (e.g. page-collection semantics that don't fit a site), record "document deferred" in the design doc and **skip Tasks 3** — proceed to Task 4. Do not contort `SiteEntity`.
- [ ] **Step 4: Run the schema test — verify PASS.**
- [ ] **Step 5: Run `swift test --package-path . --filter AnglesiteIntents` — no regression.**
- [ ] **Step 6: `xcodebuild … -scheme Anglesite … build` — BUILD SUCCEEDED, no schema diagnostics.**
- [ ] **Step 7: Commit** `feat(intents): conform SiteEntity to AppSchema.wordProcessor.document (#235)` (or commit the design-doc deferral note if skipped).

---

### Task 4: Adopt `.wordProcessor.template` (decision gate)

**Files:**
- Modify/Create: a `TemplateEntity` if one is warranted; else design-doc note.
- Test: `SchemaConformanceTests.swift`.

- [ ] **Step 1: Decision gate.** Anglesite has no `TemplateEntity` today (the template is `Resources/Template/`, not an `AppEntity`). Decide: is surfacing a `TemplateEntity` to Siri valuable on its own? If **no**, append "template: deferred — no user-facing template entity warranted in v1" to the design doc, commit that note, and skip to Task 5. If **yes**, continue.
- [ ] **Step 2 (if yes): Write the failing test** asserting `TemplateEntity.__appSchemaEntity == "wordProcessor.template"`.
- [ ] **Step 3: Run — FAIL.**
- [ ] **Step 4: Create `TemplateEntity: AppEntity` with `@AppEntity(schema: .wordProcessor.template)`** + required members per Discovery + an `EntityQuery` backed by `TemplateRuntime` template enumeration.
- [ ] **Step 5: Run schema test — PASS.**
- [ ] **Step 6: `xcodebuild … build` — SUCCEEDED.**
- [ ] **Step 7: Commit.**

---

### Task 5: Adopt `.wordProcessor.createPage` on `AddPageIntent`

The flagship intent mapping. Consumes the `createPage` Discovery row.

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift` — `AddPageIntent`.
- Test: `SchemaConformanceTests.swift`.

**Interfaces:**
- Consumes: Discovery row for `.wordProcessor.createPage`; `PageEntity` (Task 2) as the return entity (F-3 already returns `ReturnsValue<PageEntity?>`).
- Produces: `AddPageIntent.__appSchemaIntent == "wordProcessor.createPage"`.

- [ ] **Step 1: Write the failing test:**
```swift
@Test func addPageIntentCarriesCreatePageSchema() {
    #expect(AddPageIntent.__appSchemaIntent == "wordProcessor.createPage")
}
```
- [ ] **Step 2: Run — FAIL.** `swift test --package-path . --filter addPageIntentCarriesCreatePageSchema`.
- [ ] **Step 3: Add `@AppIntent(schema: .wordProcessor.createPage)`** and reconcile `@Parameter`s with the Discovery contract: rename/add only required params, keep `name`/`route`/`site` semantics, keep the `performBackgroundTask` + `LongRunningIntent`/`CancellableIntent` structure, keep the `ReturnsValue<PageEntity?>` return (map the schema's required return to `PageEntity` if it mandates one).
- [ ] **Step 4: Run the schema test — PASS.**
- [ ] **Step 5: Run the existing `AddPageIntent` behavior tests** (`ContentOperationsOverride` seam — create success returns entity, `.siteNotFound`/`.failed` returns nil + dialog). Run: `swift test --package-path . --filter AnglesiteIntents` → all PASS. Adjust the schema adoption (not the assertions) if behavior drifted.
- [ ] **Step 6: `xcodebuild … -scheme Anglesite … build` — SUCCEEDED, no schema diagnostics.**
- [ ] **Step 7: Commit** `feat(intents): conform AddPageIntent to AppSchema.wordProcessor.createPage (#235)`.

---

### Task 6: Adopt `.wordProcessor.openPage` on `PreviewSiteIntent`

`PreviewSiteIntent` opens a site's preview at an optional page → maps to "open a page". Consumes the `openPage` Discovery row.

**Files:**
- Modify: `Sources/AnglesiteIntents/ContentIntents.swift` — `PreviewSiteIntent`.
- Test: `SchemaConformanceTests.swift`.

- [ ] **Step 1: Write the failing test** asserting `PreviewSiteIntent.__appSchemaIntent == "wordProcessor.openPage"`.
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Add `@AppIntent(schema: .wordProcessor.openPage)`** and reconcile params per Discovery. **Decision gate:** if `openPage` requires a non-optional page target but `PreviewSiteIntent`'s `page` is optional (site-level preview), either (a) make the schema-required param match and keep site-level preview behavior when it's absent, or (b) if that's impossible, record "openPage deferred — PreviewSiteIntent is site-level" and skip. Do not break site-level preview.
- [ ] **Step 4: Run schema test — PASS.**
- [ ] **Step 5: Run `--filter AnglesiteIntents` — no regression** (preview routing tests).
- [ ] **Step 6: `xcodebuild … build` — SUCCEEDED.**
- [ ] **Step 7: Commit.**

---

### Task 7: `AddPostIntent` → `.wordProcessor.createPage` (decision gate)

**Files:** `Sources/AnglesiteIntents/ContentIntents.swift` — `AddPostIntent`; `SchemaConformanceTests.swift`.

- [ ] **Step 1: Decision gate.** A post is a page-like document. Decide whether `AddPostIntent` should also carry `createPage`, or stay plain to avoid two intents claiming the same schema id (which may confuse the assistant's disambiguation). Default recommendation: **adopt only if Discovery shows the assistant tolerates two intents on one schema member**; otherwise leave `AddPostIntent` plain and record the rationale. Record the decision in the design doc.
- [ ] **Step 2 (if adopting): failing test** → `AddPostIntent.__appSchemaIntent == "wordProcessor.createPage"`.
- [ ] **Step 3: Run — FAIL.**
- [ ] **Step 4: Add the macro + reconcile params** (keep `title`/`collection`/`slug` semantics and the `ReturnsValue<PostEntity?>`).
- [ ] **Step 5: schema test PASS; Step 6: `--filter AnglesiteIntents` no regression; Step 7: `xcodebuild build` SUCCEEDED.**
- [ ] **Step 8: Commit** (the adoption, or the design-doc deferral note).

---

### Task 8: `EditContentIntent` → `.wordProcessor.addImageToPage` (decision gate)

`EditContentIntent` is broader than image insertion; only its image-add path matches the schema.

**Files:** `Sources/AnglesiteIntents/EditContentIntent.swift`; `SchemaConformanceTests.swift`.

- [ ] **Step 1: Decision gate.** Review the `addImageToPage` Discovery row against `EditContentIntent`'s `element` + `instruction` params. If the schema's required members (an image asset + target page) don't fit a free-text-instruction edit intent, **do not force it** — record "addImageToPage deferred — EditContentIntent is instruction-based, not asset-targeted" in the design doc and skip. (Splitting out a dedicated `AddImageToPageIntent` is a possible future, but is out of scope for #235 unless Discovery shows a clean fit.)
- [ ] **Step 2 (if it fits): failing test** → `EditContentIntent.__appSchemaIntent == "wordProcessor.addImageToPage"`.
- [ ] **Step 3: Run — FAIL.**
- [ ] **Step 4: Add macro + reconcile params** per Discovery, preserving the `IntentEditBridge` routing + `LongRunningIntent`/`CancellableIntent` structure.
- [ ] **Step 5: schema test PASS; Step 6: `--filter AnglesiteIntents` no regression; Step 7: `xcodebuild build` SUCCEEDED.**
- [ ] **Step 8: Commit** (adoption or deferral note).

---

### Task 9: Full-surface verification — both schemes + MAS parity

**Files:** none (verification + issue updates only).

- [ ] **Step 1: Build the DevID scheme clean.** Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`, zero schema diagnostics.
- [ ] **Step 2: Build the MAS scheme clean.** Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`. (Confirms the sandboxed target's metadata extraction also accepts the conformances and the `#if ANGLESITE_MAS` gating didn't diverge the intent set.)
- [ ] **Step 3: Full test suite green.** Run: `swift test --package-path .` → all suites pass; the new `SchemaConformanceTests` assert the adopted (non-deferred) schema ids.
- [ ] **Step 4: Reframe #164 D.3.** Comment on #164: there is no `register()` to wire (SDK-confirmed in the spike); D.3's deliverable is satisfied by `SchemaConformanceTests`. Link the spike + design docs.
- [ ] **Step 5: Extend the #166 D.5 smoke checklist.** Add manual on-device checks: Siri "create a page on <site>" routes to `AddPageIntent`; "open <page>" routes to `PreviewSiteIntent`; confirm donated-Shortcut persistence survives the schema bump.
- [ ] **Step 6: Update #235.** Comment with the final adopted-vs-deferred member table (from the design doc) and close once the PR merges.
- [ ] **Step 7: Commit any doc/checklist edits**, then open the PR (base `main`) bundling the spike, design, plan, and the schema-adoption commits.

---

## Self-Review

**Spec coverage:** Goal (Siri/AI first-classness) → Tasks 2–8 adopt the surface; "wide slice incl. document/template/edit" → Tasks 3/4/8 (each with an honest decision gate, per the spec's "opt-in per intent / no force-fit" rule); "discovery-first because the contract isn't in the SDK" → Task 1; "reframe #164 D.3 as a conformance test" → Task 9 Step 4; "both schemes via xcodebuild" → Tasks 2–9; "end-to-end deferred to #166" → Task 9 Step 5; "deploy/backup/audit stay plain" → honored by omission (no task touches them). Covered.

**Placeholder scan:** No "TBD/TODO". The conformance-task parameter edits reference "the required members in the design doc's Discovery section" — that is a real Task 1 deliverable (an inter-task data dependency the skill sanctions via Consumes/Produces), not an unfilled placeholder. The introspection form (`__appSchemaIntent`) is confirmed-or-replaced in Task 1 Step 6 before any later task relies on it.

**Type consistency:** Schema ids used consistently (`wordProcessor.createPage`, `.openPage`, `.page`, `.document`, `.template`, `.addImageToPage`); generated members named `__appSchemaIntent` (intents) / `__appSchemaEntity` (entities) consistently; `SchemaConformanceTests` suite created in Task 2 and extended (not recreated) in Tasks 3–8.
