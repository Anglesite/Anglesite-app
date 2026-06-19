# Siri Edit Confirmation (#239) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require a review/confirmation before `EditContentIntent` applies a Siri-driven content edit to source files.

**Architecture:** Add a pure `ContentDialogs.editConfirmation(...)` summary helper, then insert a `requestConfirmation(dialog:)` gate into `EditContentIntent.perform()` between selector-decode and the `applyEdit` call. The gate is skipped under test scope (`IntentEditBridgeOverride.scoped`), exactly as `DeploySiteIntent` skips via `SiteOperationsOverride.scoped`. Nothing downstream of the intent changes.

**Tech Stack:** Swift 6.4 / AppIntents / Swift Testing (`@Test`). Targets `AnglesiteIntents` (lib) + `AnglesiteIntentsTests`.

## Global Constraints

- **Worktree:** all work happens in `.claude/worktrees/siri-edit-confirm/` on branch `feat/239-siri-edit-confirmation`. `cd` there before any git op.
- **ES-module / framework rules:** N/A (Swift). No frameworks beyond Apple's.
- **Toolchain:** Xcode 27+ / Swift 6.4. New code stays **outside** the `#if compiler(>=6.4)` guard — `requestConfirmation` is a base `AppIntent` API present on the CI toolchain.
- **Tests:** Swift Testing `@Test`, run with `swift test --package-path .` (needs `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` per session memory; verify the correct Xcode path before running).
- **Scope:** app-only summary, no plugin `dry_run`, no real diff (deferred follow-up). Only `EditContentIntent` is gated.
- **Curly apostrophe:** dialog copy uses the typographic apostrophe `’` (U+2019) where the existing `ContentDialogs` helpers do; the confirmation summary uses a plain `?` and `.`.

---

### Task 1: `ContentDialogs.editConfirmation` pure helper

**Files:**
- Modify: `Sources/AnglesiteIntents/EditContentIntent.swift` (extension `ContentDialogs`, after `editInvalidSelector`, ~line 122)
- Test: `Tests/AnglesiteIntentsTests/EditContentIntentTests.swift` (suite `ContentEditDialogTests`)

**Interfaces:**
- Consumes: nothing.
- Produces: `static func editConfirmation(displayName: String, pagePath: String, instruction: String) -> String` on `ContentDialogs`.

- [ ] **Step 1: Write the failing test**

Add to the `ContentEditDialogTests` suite in `Tests/AnglesiteIntentsTests/EditContentIntentTests.swift` (after the `editInvalidSelector` test, ~line 179):

```swift
        @Test("editConfirmation: names element, page, and change") func editConfirmation_full() {
            #expect(ContentDialogs.editConfirmation(
                displayName: "h1 \u{2014} Welcome",
                pagePath: "/about/",
                instruction: "make it shorter")
                    == "Update h1 \u{2014} Welcome on /about/? Change: make it shorter.")
        }

        @Test("editConfirmation: trims surrounding whitespace in the instruction") func editConfirmation_trimsInstruction() {
            #expect(ContentDialogs.editConfirmation(
                displayName: "p \u{2014} Intro",
                pagePath: "/",
                instruction: "  fix the typo  ")
                    == "Update p \u{2014} Intro on /? Change: fix the typo.")
        }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ContentEditDialogTests`
Expected: FAIL — `editConfirmation` is not a member of `ContentDialogs`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/AnglesiteIntents/EditContentIntent.swift`, inside the `extension ContentDialogs`, after the `editInvalidSelector(displayName:)` function (~line 122):

```swift
    /// Confirmation summary shown before a Siri-driven edit mutates source files (#239).
    /// Names the element, the page it lives on, and the requested change so the user can
    /// review before confirming. App-only summary — a structured diff is a deferred follow-up
    /// gated on a plugin `apply_edit` dry-run.
    public static func editConfirmation(displayName: String, pagePath: String, instruction: String) -> String {
        let change = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Update \(displayName) on \(pagePath)? Change: \(change)."
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter ContentEditDialogTests`
Expected: PASS (both new tests + the existing dialog tests).

- [ ] **Step 5: Commit**

```bash
cd .claude/worktrees/siri-edit-confirm
git add Sources/AnglesiteIntents/EditContentIntent.swift Tests/AnglesiteIntentsTests/EditContentIntentTests.swift
git commit -m "feat(#239): add editConfirmation summary helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Confirmation gate in `EditContentIntent.perform()`

**Files:**
- Modify: `Sources/AnglesiteIntents/EditContentIntent.swift:45-68` (`perform()`)
- Test: `Tests/AnglesiteIntentsTests/EditContentIntentTests.swift` (suite `EditContentIntentTests`)

**Interfaces:**
- Consumes: `ContentDialogs.editConfirmation(displayName:pagePath:instruction:)` (Task 1); existing `IntentEditBridgeOverride.scoped`, `element.selectorJSON()`, `resolved.applyEdit(...)`.
- Produces: gated `perform()` — under test scope (`IntentEditBridgeOverride.scoped != nil`) the prompt is skipped and routing is unchanged; in production the prompt precedes routing.

- [ ] **Step 1: Write the failing test**

The behavioral contract testable in unit scope: the confirmation gate must NOT change routing when test scope is active, and must still be skipped before the invalid-selector early-return (no prompt on a bad selector). Add to the `EditContentIntentTests` suite (after `perform_invalidSelectorSkipsBridge`, ~line 114):

```swift
        @Test("perform still routes under test scope after the confirmation gate is added")
        func perform_gateSkippedUnderTestScope() async throws {
            let router = RecordingRouter(reply: EditReply(
                id: "fixed", status: .applied, message: nil, file: "src/pages/about.astro"
            ))
            let intent = EditContentIntent()
            intent.element = Self.fixture()
            intent.instruction = "make it shorter"

            // IntentEditBridgeOverride.scoped is set, so the confirmation prompt is skipped
            // (it has no UI surface in tests) and the edit routes as before.
            try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(router: router)) {
                _ = try await intent.perform()
            }
            #expect(await router.received.count == 1, "test-scoped edit must route past the confirmation gate")
        }
```

> Note: production confirm/cancel goes through the SDK `requestConfirmation`, which is not
> introspectable in unit tests. Cancel-leaves-tree-unchanged is covered structurally: a thrown
> `requestConfirmation` exits `perform()` before `applyEdit`. The existing
> `perform_invalidSelectorSkipsBridge` test already proves the no-route/zero-message path.

- [ ] **Step 2: Run test to verify it passes against current code, then confirm the gate keeps it passing**

Run: `swift test --package-path . --filter EditContentIntentTests`
Expected: PASS now (no gate yet). This test is a regression guard for the gate — it must stay green after Step 3.

- [ ] **Step 3: Add the confirmation gate**

In `Sources/AnglesiteIntents/EditContentIntent.swift`, change `perform()` (lines 45-58). Replace:

```swift
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let resolved = IntentEditBridgeOverride.scoped ?? bridge
        guard let selector = element.selectorJSON() else {
            return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.editInvalidSelector(
                displayName: element.displayName
            )))
        }
        let reply = await resolved.applyEdit(
```

with:

```swift
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let scoped = IntentEditBridgeOverride.scoped
        let resolved = scoped ?? bridge
        guard let selector = element.selectorJSON() else {
            return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.editInvalidSelector(
                displayName: element.displayName
            )))
        }
        // #239: Siri must review the edit before it mutates source files. Confirm after the
        // target is resolved (so the summary names the element/page) and before routing (so a
        // decline leaves the working tree untouched — `perform` exits here, never calling the
        // bridge). Skipped under test scope, which has no UI surface — same pattern as the
        // Site intents' `SiteOperationsOverride.scoped` guard around `requestConfirmation`.
        if scoped == nil {
            try await requestConfirmation(dialog: IntentDialog(stringLiteral: ContentDialogs.editConfirmation(
                displayName: element.displayName,
                pagePath: element.pagePath,
                instruction: instruction
            )))
        }
        let reply = await resolved.applyEdit(
```

(The rest of `perform()` — the `applyEdit` call, the cancellation check, and the `editReply` dialog dispatch — is unchanged.)

- [ ] **Step 4: Run the full intents suite to verify nothing regressed**

Run: `swift test --package-path . --filter AnglesiteIntentsTests`
Expected: PASS — all existing `EditContentIntentTests` (including the four that route under test scope) plus the new gate guard.

- [ ] **Step 5: Build the app target to confirm the gate compiles outside the `#if` guard**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED. (If `Anglesite.xcodeproj` is missing in the worktree, run `xcodegen generate` first.)

- [ ] **Step 6: Commit**

```bash
cd .claude/worktrees/siri-edit-confirm
git add Sources/AnglesiteIntents/EditContentIntent.swift Tests/AnglesiteIntentsTests/EditContentIntentTests.swift
git commit -m "feat(#239): require confirmation before Siri applies a content edit

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Doc + comment alignment

**Files:**
- Modify: `Sources/AnglesiteIntents/EditContentIntent.swift` (the doc comment on `EditContentIntent`, lines 5-25)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing (documentation only).

- [ ] **Step 1: Update the wire-up doc comment**

The struct doc comment (lines 7-19) lists the perform steps. Update step 3's wire-up bullet to mention the confirmation gate. Change the line that begins `/// 3. \`perform()\` decodes the entity's stored selector…` to note the gate. Replace:

```swift
/// 3. `perform()` decodes the entity's stored selector back into a structured `JSONValue`,
///    builds an `EditMessage`, and routes it via `IntentEditBridge` →
```

with:

```swift
/// 3. `perform()` decodes the entity's stored selector back into a structured `JSONValue`,
///    confirms the change with the user (#239 — review before mutating source files; skipped
///    under test scope), then builds an `EditMessage` and routes it via `IntentEditBridge` →
```

- [ ] **Step 2: Verify it builds**

Run: `swift build --package-path .`
Expected: Build complete (no test run needed for a comment change).

- [ ] **Step 3: Commit**

```bash
cd .claude/worktrees/siri-edit-confirm
git add Sources/AnglesiteIntents/EditContentIntent.swift
git commit -m "docs(#239): note confirmation gate in EditContentIntent wire-up

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- "confirmation gate between selector-decode and applyEdit" → Task 2 Step 3. ✓
- "human-readable summary from resolved inputs" → Task 1. ✓
- "reuse `IntentEditBridgeOverride.scoped` as test seam" → Task 2 Step 3 (`if scoped == nil`). ✓
- "failed-preview path = existing `editInvalidSelector` guard, no prompt/route" → preserved in Task 2 Step 3 (guard is before the gate); existing `perform_invalidSelectorSkipsBridge` test covers it. ✓
- "confirm path routes via unchanged pipeline" → Task 2 Step 1 test + unchanged downstream. ✓
- "cancel leaves tree unchanged" → structural (throw exits before `applyEdit`); documented in Task 2 note. ✓
- "structured diff deferred" → not implemented, called out in Global Constraints. ✓
- "acceptance: confirm/cancel/failed-preview unit coverage" → Task 1 helper tests, Task 2 routing/skip test, existing invalid-selector test. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `editConfirmation(displayName:pagePath:instruction:)` signature is identical in Task 1 (definition), Task 1 tests, and Task 2 call site. `IntentEditBridgeOverride.scoped`, `element.pagePath`, `element.displayName`, `element.selectorJSON()` all match the current source read during planning. ✓
