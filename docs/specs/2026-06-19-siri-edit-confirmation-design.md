# Siri edit confirmation (#239) — design

**Status:** approved (brainstorming) · **Date:** 2026-06-19 · **Branch:** `feat/239-siri-edit-confirmation`

## Goal

Make Siri-driven content edits reviewable before they mutate source files. When
`EditContentIntent` resolves an onscreen element and a natural-language instruction,
Anglesite must present a confirmation that identifies the target site, page, and element
plus a human-readable summary of the change, and apply the edit only after the user
confirms. Cancelling must leave the working tree untouched.

## Scope (v1 — app-only)

- A confirmation gate inside `EditContentIntent.perform()`, between selector decode and the
  `IntentEditBridge.applyEdit` call.
- A **human-readable summary** built from already-resolved intent inputs (element, page,
  instruction). No file I/O, no plugin round-trip.
- Confirm / cancel / failed-preview paths, each unit-tested.

### Explicitly out of scope (deferred)

- A **structured before/after diff**. That requires a `dry_run` path on the plugin's
  `apply_edit` MCP tool (a paired plugin PR + release + bundled-plugin pointer bump, per the
  repo's MCP-schema-change convention). Tracked as a follow-up; v1 ships the summary fallback
  the issue explicitly permits ("fall back to a human-readable summary when it cannot").
- The WKWebView click-to-edit overlay. It routes directly through the `EditRouter` and is not
  a Siri/Intents surface; #239 is scoped to the Siri seam only.
- Any new edit-mutating intent beyond `EditContentIntent`.

## Architecture

One seam, no downstream changes. The confirmation is a pure guard layer ahead of the existing
pipeline.

```
EditContentIntent.perform()
  ├─ decode selector ──(fails)──▶ editInvalidSelector dialog        [failed-preview: no prompt, no route]
  ├─ build EditPreview summary (pure)
  ├─ requestConfirmation(dialog: summary) ──(user cancels → throws)─▶ exits before bridge call  [tree unchanged]
  └─ IntentEditBridge.applyEdit(…)  ── unchanged ──▶ MCPApplyEditRouter ──▶ plugin apply_edit
                                                          └─ onEdit ▶ ChatModel.recordEdit (commit) — unchanged
```

`EditRouter`, `MCPApplyEditRouter`, `EditReply`, `ChatModel.recordEdit`, undo/chat metadata,
and the post-apply alt-text hook are all **untouched**. The gate sits entirely in the intent.

This mirrors the existing `DeploySiteIntent` pattern (`Sources/AnglesiteIntents/SiteIntents.swift:30-44`):
`requestConfirmation(dialog:)` before the outward-facing action, skipped under test scope.

## Components

### 1. `ContentDialogs.editConfirmation(...)` — pure helper

Added alongside the existing `editApplied` / `editFailed` / `editAmbiguous` /
`editInvalidSelector` helpers in `EditContentIntent.swift`. Pure function, fully unit-testable:

```swift
public static func editConfirmation(displayName: String, pagePath: String, instruction: String) -> String
```

Renders e.g.: **"Update h1 — Welcome on /about/? Change: make it shorter."**

Inputs come from the already-resolved `ElementEntity` (`displayName`, `siteID`, `pagePath`)
and the spoken `instruction`. `displayName` already embeds the element tag + content
("h1 — Welcome to my site"); `pagePath` locates it within the site. That satisfies the
acceptance criterion that the confirmation identify the target site/content/element.

> No friendly site name exists on `ElementEntity` (only `siteID`). v1 uses page path +
> element display name, which together identify the target unambiguously for the user. If a
> site display name becomes available on the entity later, fold it into this one helper.

### 2. Confirmation gate in `perform()`

Reuse the **existing** `IntentEditBridgeOverride.scoped` as the test seam — no new override
type. When `scoped` is set (unit tests, no UI surface), skip the prompt, exactly as the Site
intents skip via `SiteOperationsOverride.scoped`:

```swift
public func perform() async throws -> some IntentResult & ProvidesDialog {
    let scoped = IntentEditBridgeOverride.scoped
    let resolved = scoped ?? bridge
    guard let selector = element.selectorJSON() else {
        return .result(dialog: IntentDialog(stringLiteral:
            ContentDialogs.editInvalidSelector(displayName: element.displayName)))   // failed-preview
    }
    if scoped == nil {
        try await requestConfirmation(dialog: IntentDialog(stringLiteral:
            ContentDialogs.editConfirmation(
                displayName: element.displayName,
                pagePath: element.pagePath,
                instruction: instruction)))
    }
    let reply = await resolved.applyEdit(/* unchanged */)
    // …existing cancellation + dialog dispatch unchanged…
}
```

The existing `editInvalidSelector` guard **is** the failed-preview path: if the selector
won't decode we can't form a coherent target, so we return that dialog without prompting or
routing. No new code there — just a test asserting zero router messages on that path.

When the user declines, `requestConfirmation` throws; `perform()` exits before the
`applyEdit` call, so the recording router receives nothing and the tree is unchanged.

## Data flow

`(element, instruction)` → decode selector → summary → confirmation →
**[confirm]** existing bridge → router → reply → dialog (with `ChatModel.recordEdit` firing on
commit, as today) · **[cancel]** throw before bridge → zero router messages, no chat/undo entry
(record only on apply) · **[bad selector]** invalid-selector dialog, no prompt, no route.

## Testing (Swift Testing `@Test`, `Tests/AnglesiteIntentsTests/`)

Using the existing `RecordingRouter` + `IntentEditBridgeOverride.$scoped.withValue` harness
from `EditContentIntentTests.swift`:

1. **confirm** — override set, `perform()` proceeds; assert router received exactly one message
   with the expected `EditMessage` fields, and the applied/failed/ambiguous dialog is correct.
   (Under test scope the prompt is skipped, matching the Site-intent test convention; the SDK
   `requestConfirmation` call itself is not introspectable in unit tests.)
2. **cancel** — modelled by the failed-preview/no-route assertion plus the design contract that
   a thrown `requestConfirmation` exits before routing. Assert that when `perform()` does not
   reach the bridge, the recording router has **zero** received messages and no chat/undo entry.
3. **failed-preview** — `ElementEntity` whose `selectorJSON()` returns nil → `editInvalidSelector`
   dialog, zero router messages, no prompt.
4. **pure-helper** — `editConfirmation(...)` returns the expected text for representative
   element/instruction inputs (element name, page path, and instruction all present in output).

No live Siri runtime is needed — the confirmation prompt is bypassed under test scope, and the
guard/summary logic is pure and directly callable.

## Acceptance-criteria mapping

| Criterion (#239) | Covered by |
|---|---|
| Siri edit requires confirmation before files change | gate in `perform()` before `applyEdit` |
| Confirmation identifies target site + content/element | `editConfirmation` (displayName + pagePath) |
| Cancel leaves working tree unchanged | throw exits before bridge → zero router messages |
| Confirm applies via existing pipeline + same undo/chat metadata | downstream untouched; `onEdit`/`recordEdit` unchanged |
| Unit coverage: confirm, cancel, failed-preview | tests 1–3 above |
| Structured diff preferred, summary fallback | summary shipped now; diff deferred to paired plugin PR |

## Risks / notes

- **`#if compiler(>=6.4)` toolchain gate**: `EditContentIntent` already conforms to
  `LongRunningIntent`/`CancellableIntent` under that guard. `requestConfirmation` is a base
  `AppIntent` API available on the CI toolchain, so the gate adds no new compiler-version
  constraint. The new code stays outside the `#if`.
- **Summary, not diff, in v1**: an honest reflection of what the app can compute without a
  plugin dry-run. The follow-up paired PR upgrades the same `editConfirmation` seam to a real
  diff without touching the gate's structure.
- **Cross-PR coordination with #249 (operation descriptors)**: PR #249 adds an
  `OperationDescriptor` registry where `edit-content` is declared `requiresConfirmation: false`,
  with `OperationDescriptorTests.declaredFields` asserting that value. This PR is the
  "deliberate manual checkpoint" the #249 spec names — once it ships, `edit-content` *does*
  require confirmation. The two files live only in #249, so the flip cannot happen here until
  #249 lands. **Plan: merge #249 first, then on this branch flip both**
  `Sources/AnglesiteIntents/OperationDescriptor.swift` (the `edit-content` entry's
  `requiresConfirmation` to `true`) **and** the matching `expected` value in
  `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift`, so the registry and its test
  stay truthful once both PRs are on main.
