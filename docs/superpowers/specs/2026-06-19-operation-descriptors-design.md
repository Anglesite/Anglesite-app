# Operation Descriptors for Intents and System MCP Tools

**Issue:** [#235](https://github.com/Anglesite/Anglesite-app/issues/235) — Siri AI Phase D
**Date:** 2026-06-19
**Status:** Design approved

## Goal

Give Anglesite a single, lean, **test-enforced** description of each Siri-facing
operation — its side-effect level, confirmation requirement, cancellability, and
result shape — so Siri, Shortcuts, and the auto-derived system MCP surface can't
drift from what the intents actually do.

## Why

macOS 27's `mcpbridge` auto-derives MCP tool schemas from App Intent / `AppEntity`
metadata. D.2 ([#163](https://github.com/Anglesite/Anglesite-app/issues/163))
deliberately chose to **enrich that auto-derived schema** rather than maintain a
parallel hand-written MCP surface that could drift. This issue stays faithful to
that decision: the descriptor captures **only what the auto-derived schema cannot
express** (side-effect risk, confirmation, cancellability, a human-readable result
label) and ties those claims to real intent behavior with tests. It is a
*consistency contract*, not a second catalog of parameters.

## Non-goals

- **No re-declaration of input parameters.** Those are already promoted via
  `@Parameter` / `@Property` (D.2 F-1) and flow into the auto-derived schema.
  Re-listing them here is exactly the drift risk we are avoiding.
- **No `AnglesiteMCPRegistration` / custom MCP tool registration.** Deferred per
  D.2's YAGNI call until the D.5 manual smoke
  ([#166](https://github.com/Anglesite/Anglesite-app/issues/166)) proves the bridge
  has a concrete gap. `bootstrap()` is untouched.
- **No cancellation behavior.** Real cancellation wiring is
  [#238](https://github.com/Anglesite/Anglesite-app/issues/238)'s scope. The
  descriptor *declares* cancellability as a field; it does not implement it.
- **No edit-confirmation behavior.** Adding confirmation to `EditContentIntent` is
  [#239](https://github.com/Anglesite/Anglesite-app/issues/239). The descriptor
  reflects today's reality (`requiresConfirmation: false` for edit); the behavioral
  cross-check forces it to update when #239 lands.
- **No consumer wiring.** This issue ships the model + registry + enforced tests
  only. Diagnostics ([#236](https://github.com/Anglesite/Anglesite-app/issues/236),
  in progress) consumes it next.

## The model

New file: `Sources/AnglesiteIntents/OperationDescriptor.swift`.

```swift
public struct OperationDescriptor: Sendable, Equatable {
    public let operationID: String          // stable slug: "deploy-site"
    public let displayName: String          // "Deploy Site"
    public let intentTypeName: String        // "DeploySiteIntent" — the anchor key
    public let sideEffect: OperationSideEffect
    public let requiresConfirmation: Bool
    public let isCancellable: Bool
    public let resultShape: OperationResult
    public let mcpToolName: String?           // auto-derived bridge name, if known
}

public enum OperationSideEffect: Sendable {
    case readOnly        // does not mutate site source
    case createsContent  // adds new files (pages, posts)
    case modifiesContent // changes existing files / local state (backup, edit)
    case publishes       // pushes to production (deploy)
}

public enum OperationResult: Sendable, Equatable {
    case none                 // dialog-only intent
    case entity(String)       // ReturnsValue<T> — type name, e.g. "SiteEntity"
    case entities(String)     // ReturnsValue<[T]> — element type name
}
```

`sideEffect` describes mutation of **site/content source**, which is what drives
confirmation decisions. Operations that spawn subprocesses but don't touch site
source (audit, preview, status, search) are `readOnly`.

`mcpToolName` is a forward-looking field for the `mcpbridge`-assigned tool name.
Apple's exact auto-derived naming convention is not yet known, so it is `nil` for
**all** current entries; it is reserved for when D.5 ([#166]) pins the convention
down. It is not asserted by any test today.

## The registry

`AnglesiteOperations.all: [OperationDescriptor]` (in the same file) is the single
canonical source of truth. Classification of the 10 current operations:

| operationID | intent | sideEffect | confirm | cancellable | result |
|---|---|---|---|---|---|
| `deploy-site` | `DeploySiteIntent` | `publishes` | **true** | true | `.entity("SiteEntity")` |
| `backup-site` | `BackupSiteIntent` | `modifiesContent` | false | true | `.entity("SiteEntity")` |
| `audit-site` | `AuditSiteIntent` | `readOnly` | false | true | `.entity("SiteEntity")` |
| `open-site` | `OpenSiteIntent` | `readOnly` | false | false | `.none` |
| `search-content` | `SearchContentIntent` | `readOnly` | false | false | `.entities("ContentMatchEntity")` |
| `site-status` | `SiteStatusIntent` | `readOnly` | false | false | `.none` |
| `preview-site` | `PreviewSiteIntent` | `readOnly` | false | true | `.none` |
| `add-page` | `AddPageIntent` | `createsContent` | false | false | `.entity("PageEntity")` |
| `add-post` | `AddPostIntent` | `createsContent` | false | false | `.entity("PostEntity")` |
| `edit-content` | `EditContentIntent` | `modifiesContent` | false | false | `.none` |

`OpenSiteIntent` is included (it is MCP-exposable via `mcpbridge`) even though it
has no curated Siri phrase, so it is **not** coverage-enforced by the anchor below.
The registry is intentionally more complete than the enforced floor.

## The App Shortcuts anchor

The canonical set of *Siri-facing* operations is anchored to `AnglesiteShortcuts`
(the `AppShortcutsProvider`). Apple's `appShortcuts` returns type-erased
`[AppShortcut]` with no public API to read back the intent *type*, so a test cannot
introspect the provider directly. The mechanic works around that with a
test-visible name list co-located with the phrase definitions:

```swift
extension AnglesiteShortcuts {
    /// Intent type names that have a curated Siri phrase. Kept beside `appShortcuts`
    /// so adding/removing a phrase naturally updates this — the anchor for
    /// descriptor coverage.
    static let phraseExposedIntentNames: Set<String> = [
        "DeploySiteIntent", "BackupSiteIntent", "AuditSiteIntent",
        "SearchContentIntent", "SiteStatusIntent", "PreviewSiteIntent",
        "AddPageIntent", "AddPostIntent", "EditContentIntent",
    ]
}
```

**Known boundary:** this hand-maintained list is the price of Apple's type erasure.
A guard test (below) asserts its size matches the actual `appShortcuts` count, so it
cannot silently fall out of sync. Detection of a *non-shortcut* MCP-exposed intent
shipped without a descriptor is **not** possible without conformer reflection; the
enforced floor is the shortcut set.

## Test strategy

New file: `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift`, Swift
Testing (`@Test`/`#expect`), reusing the existing fake-service seams
(`SiteOperationsOverride.scoped`, `ContentGraphOverride.scoped`, etc.).

1. **Coverage** — `AnglesiteShortcuts.phraseExposedIntentNames` is a subset of
   `Set(AnglesiteOperations.all.map(\.intentTypeName))`. Adding a Siri phrase
   without a descriptor fails here.
2. **Anchor sync guard** — `AnglesiteShortcuts.appShortcuts.count ==
   phraseExposedIntentNames.count`, so the hand-list can't drift from the provider.
3. **Uniqueness** — `operationID` and `intentTypeName` are each unique across the
   registry.
4. **Confirmation agreement** — drive each `publishes`/`modifiesContent`/
   `createsContent` intent through its fake service and assert `requestConfirmation`
   was invoked **iff** `descriptor.requiresConfirmation`. (Generalizes the existing
   `DeploySiteIntentTests` confirmation assertion across the whole table.)
5. **Side-effect agreement** — assert a mutating service method was called **iff**
   `descriptor.sideEffect != .readOnly`; for `.readOnly` ops assert no mutating
   method fired.
6. **Result-shape agreement** — assert `.entity`/`.entities`/`.none` matches each
   intent's actual `ReturnsValue<…>` / dialog-only return (statically known).

`isCancellable` gets **no** behavioral test — real cancellation is #238's scope, so
it is a declared field only. This gap is intentional, documented here so it reads as
a deliberate boundary rather than an oversight.

## Files

- **New:** `Sources/AnglesiteIntents/OperationDescriptor.swift` — model +
  `AnglesiteOperations.all`.
- **New:** `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift` — the six
  test groups above.
- **Touched:** `Sources/AnglesiteIntents/AnglesiteShortcuts.swift` — add
  `phraseExposedIntentNames`.
- **Untouched:** `Bootstrap.swift` (no MCP registration this issue).

## Acceptance criteria mapping

| Issue acceptance criterion | Satisfied by |
|---|---|
| Deploy/edit operations marked as requiring confirmation | Deploy `requiresConfirmation: true`; edit reflects current `false` with the behavioral cross-check forcing it to track #239 |
| Read-only operations marked as non-destructive | `sideEffect: .readOnly` for audit/open/search/status/preview, verified by the side-effect agreement test |
| Descriptors cover the current Siri-facing operations | Coverage test (anchor subset) |
| Tests catch missing descriptors for new Siri-facing intents/tools | Coverage + anchor-sync guard tests |

## Build / verification

`swift test --package-path .` (filtered to `AnglesiteIntentsTests`). Both schemes
(`Anglesite`, `AnglesiteMAS`) must build — the new types are plain value types in
`AnglesiteIntents`, no target-specific gating.
