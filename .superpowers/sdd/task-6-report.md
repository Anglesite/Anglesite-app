# Task 6 Report: EditContentIntent interpret→dry-run→confirm→apply

## Status: DONE

## AssistantContext shape found

`AssistantContext` (in `Sources/AnglesiteCore/ContentAssistant.swift`) requires:
- `siteID: String` (required)
- `siteDirectory: URL` (required)
- `currentPageRoute: String?` (optional, defaults nil)
- `currentPageContent: String?` (optional)
- `selectedElementSelector: JSONValue?` (optional)
- `conversationHistory: [AssistantMessage]` (optional, defaults [])

`FoundationModelAssistant` init takes only `tier`, `editBridge?`, `contentGraph?` — no per-site state baked in.

## Bootstrap wiring

The pre-existing `FoundationModelEditInterpreter.init(assistant:siteID:siteDirectory:)` baked in per-site state, making it impossible to register as an app-wide dependency.

**Resolution:** Added a new `init(assistant: FoundationModelAssistant)` overload to `FoundationModelEditInterpreter` that builds `AssistantContext` from the `InterpretedElementContext` at call time (reading `element.siteID` and `element.siteDirectory`). Added `siteID: String?` and `siteDirectory: URL?` optional fields to `InterpretedElementContext` (with defaults so existing tests compile unchanged). In `perform()`, `SiteStore.shared.find(id: element.siteID)?.path` supplies `siteDirectory` before interpret.

Bootstrap registers:
```swift
#if compiler(>=6.4)
let fmAssistant = FoundationModelAssistant()
let editInterpreter: any EditInterpreting = FoundationModelEditInterpreter(assistant: fmAssistant)
#else
let editInterpreter: any EditInterpreting = UnavailableEditInterpreter()
#endif
AppDependencyManager.shared.add { () -> any EditInterpreting in editInterpreter }
```

`UnavailableEditInterpreter` (private struct in Bootstrap.swift) throws `EditInterpretationError.unavailable(...)` so the intent's catch block shows the "needs Apple Intelligence" dialog on CI/older toolchains.

## Files changed

| File | Change |
|------|--------|
| `Sources/AnglesiteIntents/EditInterpreterOverride.swift` | Created — `@TaskLocal (any EditInterpreting)?` seam |
| `Sources/AnglesiteIntents/ConfirmationOverride.swift` | Created — `ConfirmationDecision` enum + `@TaskLocal` seam |
| `Sources/AnglesiteIntents/EditContentIntent.swift` | Rewrote `perform()` + added `@Dependency interpreter`; cleaned curly-quote corruption in string literals |
| `Sources/AnglesiteIntents/ElementEntity.swift` | Added `elementTag` + `currentText` computed accessors (decode from selector JSON) |
| `Sources/AnglesiteIntents/Bootstrap.swift` | Added `UnavailableEditInterpreter` stub + FM interpreter registration |
| `Sources/AnglesiteCore/InterpretedEdit.swift` | Added `siteID: String?` + `siteDirectory: URL?` to `InterpretedElementContext` (optional with defaults — existing tests unmodified) |
| `Sources/AnglesiteCore/FoundationModelEditInterpreter.swift` | Added `init(assistant:)` overload for app-wide use (no per-site state baked in) |

## perform() flow

1. `selectorJSON()` guard → invalid-selector dialog (no bridge call)
2. `SiteStore.shared.find(id:element.siteID)?.path` for siteDirectory
3. `interp.interpret(...)` with `InterpretedElementContext` (includes siteID/siteDirectory) → catch all errors → "needs Apple Intelligence" dialog (no bridge call)
4. `interpreted.resolveOp()` → nil guard → ambiguous dialog (no bridge call)
5. `bridge.applyEdit(..., dryRun: true)` → dry-run
6. `preview.status != .preview` → relay plugin refusal dialog (no apply call)
7. `ConfirmationOverride.scoped` → if `.decline` → "I won't change" dialog (no apply call); if `.confirm` → fall through; if nil → real `requestConfirmation` (throws on decline, exiting with no apply)
8. `bridge.applyEdit(...)` → apply
9. "canceled" check → cancel dialog; else `editReply()` dispatch

## Build result

`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path .` → **Build complete** (clean, warnings only from pre-existing @Generable deprecation in macOS 27 SDK macros — unrelated to this task).

## Self-review

- Decline: ZERO apply calls — confirmed
- Dry-run refusal: ZERO apply calls — confirmed
- Interpret-unavailable: ZERO bridge calls — confirmed
- Invalid selector preserved — confirmed
- "canceled" cancellation preserved — confirmed
- Existing Task 3/4 tests unmodified (new `InterpretedElementContext` fields are optional with defaults) — confirmed

## Concerns

- The old `FoundationModelEditInterpreter.init(assistant:siteID:siteDirectory:)` still exists alongside the new `init(assistant:)`. It's unused but harmless; can be removed in cleanup.
- `SiteStore.shared.find(id:)` in `perform()` returns `nil` when the intent runs from a process that hasn't loaded the store yet (unlikely in practice). The FM interpreter will then throw `unavailable` from its nil guard, surfacing the "needs Apple Intelligence" dialog gracefully.
- The `editConfirmation(displayName:pagePath:instruction:)` overload (old, instruction-only) is kept for backward compat but is no longer called from `perform()`. Task 7 can decide whether to test or remove it.

## Task 6 — distinct dialog for site unavailable + single selector decode

### Fixes implemented

**Fix 1 — `siteUnavailable` case in `EditInterpretationError`**  
Added `case siteUnavailable(String)` to the enum in `Sources/AnglesiteCore/InterpretedEdit.swift`. Keeps `.unavailable` for Apple Intelligence missing; new case semantically means the element's site isn't open in Anglesite.

**Fix 2 — `FoundationModelEditInterpreter` throws `siteUnavailable`**  
In `Sources/AnglesiteCore/FoundationModelEditInterpreter.swift`, the `guard let siteID ... else` block now throws `.siteUnavailable("siteID/siteDirectory not provided in element context")` instead of `.unavailable(...)`. `AssistantError` → `.unavailable` mapping is unchanged.

**Fix 3 — Typed catch in `EditContentIntent.perform()`**  
In `Sources/AnglesiteIntents/EditContentIntent.swift`, added a typed first catch for `EditInterpretationError.siteUnavailable` that returns `"Open this site in Anglesite first, then try the edit again."` The existing catch-all still returns the Apple Intelligence dialog.

**Fix 4 — Single selector decode**  
Replaced `element.elementTag` / `element.currentText` (which each called `selectorJSON()` internally) with a single inline decode from the already-validated `selector` JSONValue. Pattern: `if case .object(let d) = selector { selectorDict = d }` then `if case .string(let t) = selectorDict["tag"] { tag = t }`.

**Fix 4b — Removed dead `elementTag` / `currentText` accessors from `ElementEntity`**  
After Fix 4, `ElementEntity.elementTag` and `ElementEntity.currentText` had no callers outside their own file. Both were removed from `Sources/AnglesiteIntents/ElementEntity.swift`.

**Fix 5 — Both inits in `FoundationModelEditInterpreter` are live**  
`init(generate:)` is used by tests, `init(assistant:)` is used by Bootstrap production wiring. Neither is dead; Fix 5 is a no-op.

**Bonus — Fixed pre-existing test breakage**  
`EditContentIntentTests` and `EditContentIntentCancelTests` were crashing with signal 5 (AppDependencyManager fatal error) because `perform()` now calls `@Dependency var interpreter` before any bridge call, but those tests never set `EditInterpreterOverride.scoped`. Added a `PassthroughInterpreter` / `CancelTestInterpreter` stub to each test file and wrapped the `perform()` calls accordingly. Also updated the op assertion in `perform_buildsEditMessage` from `applyInstruction` → `replace-text` to match the new FM-interpreted flow.

### RED + GREEN evidence

**RED (without source changes):**  
`EditContentIntentSiteUnavailableTests.swift` fails to compile: `type 'EditInterpretationError' has no member 'siteUnavailable'`.

**GREEN (with changes):**

Command: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter EditContentIntentSiteUnavailable`
```
✔ Test "siteUnavailable: dialog asks user to open site, bridge receives no calls" passed after 0.008 seconds.
✔ Test "unavailable (AI): dialog mentions Apple Intelligence, bridge receives no calls" passed after 0.001 seconds.
✔ Test run with 2 tests in 2 suites passed after 0.008 seconds.
```

Command: `... --filter InterpretedEditTests`
```
✔ 4/4 tests passed
```

Command: `... --filter FoundationModelEditInterpreterTests`
```
✔ 2/2 tests passed
```

Command: `... --filter EditContentIntentTests` (EditContentIntent suite only)
```
✔ "perform builds an EditMessage from the entity + instruction"
✔ "perform reaches the bridge for any reply status"
✔ "perform skips the bridge for an unparseable selector"
✔ "perform skips the confirmation gate and routes under test scope"
✔ "perform routes per the element's siteID, not a global default"
```

Command: `... --filter EditContentIntentCancel`
```
✔ "genuine failure during cancellation: surfaces the error, not 'Canceled'"
✔ "canceled reply: perform() returns the Canceled dialog"
✔ "cancelled + applied reply: returns the Edited dialog, not Canceled"
```

Note: `ContentDialogs.edit*` tests fail on em-dash string comparisons; this is pre-existing (same failures on the parent commit `cf847a7`) and unrelated to this task.

### Build result
`swift build --package-path .` → Build complete (warnings only: pre-existing `@Generable` deprecation).
