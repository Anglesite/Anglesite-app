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
| `preview-site` | `PreviewSiteIntent` | `readOnly` | false | false | `.none` |
| `add-page` | `AddPageIntent` | `createsContent` | false | true | `.entity("PageEntity")` |
| `add-post` | `AddPostIntent` | `createsContent` | false | true | `.entity("PostEntity")` |
| `edit-content` | `EditContentIntent` | `modifiesContent` | false | true | `.none` |

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

The verification is a **honest hybrid**: behavioral where the existing fake-service
seams allow it, and declared-field value assertions (not behavioral) where the seams
genuinely cannot observe the behavior. The boundaries below are deliberate, not
oversights — they reflect two hard limits of unit-testing App Intents under
`swift test`:

- **Confirmation is unobservable.** Every intent's `perform()` *bypasses*
  `requestConfirmation` when its test seam is active (`SiteOperationsOverride.scoped
  != nil` → skip), because calling `requestConfirmation` outside the live AppIntents
  runtime crashes. macOS 27's App Intents Testing could observe it but needs a hosted
  app target, which CI's macos-15 runner can't launch. So no `swift test` can witness
  whether confirmation fires.
- **Read-vs-write is unobservable for the three site ops.** `deploy`, `backup`, and
  `audit` all invoke a `SiteOperationsService` command method, so "a command fired"
  can't distinguish `audit` (readOnly) from `deploy` (write). The clean read/write
  split only exists for **content** intents (`createPage`/`createPost` vs graph-only
  reads) and **edit** (edit-bridge call).

The test groups:

1. **Coverage** *(data)* — `AnglesiteShortcuts.phraseExposedIntentNames` is a subset
   of `Set(AnglesiteOperations.all.map(\.intentTypeName))`. Adding a Siri phrase
   without a descriptor fails here.
2. **Anchor sync guard** *(data)* — `AnglesiteShortcuts.appShortcuts.count ==
   phraseExposedIntentNames.count`, so the hand-list can't drift from the provider.
3. **Uniqueness** *(data)* — `operationID` and `intentTypeName` are each unique
   across the registry.
4. **Routing agreement** *(behavioral)* — drive each intent's `perform()` in scoped
   mode and assert it invokes the service call matching its operation: `deploy` →
   `deployCalls == 1`, `backup` → `backupCalls == 1`, `audit` → `auditCalls == 1`,
   `add-page` → `createPage`, `add-post` → `createPost`, `edit-content` → the
   edit-bridge call. Proves each descriptor maps to a real invoked operation, not a
   phantom. (`open`/`site-status`/`preview`/`search` route to the window router or
   graph reads, asserted as *no* content-mutating call — see group 5.)
5. **Content-mutation agreement** *(behavioral)* — splits across two assertions
   rather than one registry-driven `iff`. The non-readOnly direction is covered by
   group 4's routing tests (`add-page`→`createPage`, `add-post`→`createPost`,
   `edit-content`→edit-bridge each fire). The readOnly direction is covered by a
   `readsDoNotMutate` test that drives `SearchContentIntent` and `SiteStatusIntent`
   with the create-side seam in scope and asserts no `createPage`/`createPost` fired.
   So `add-page` mis-marked `.readOnly` (routing test fires a create) or `search`/
   `site-status` mis-driving a create both fail CI. **Boundary:** `preview-site` and
   `open-site` are *not* behaviorally exercised here (they need WindowRouter/preview
   fixtures); their `.readOnly` `sideEffect` is value-asserted in group 6, not
   behaviorally enforced.
6. **Declared-field value assertions** *(data, not behavioral)* — per operation,
   assert the expected `requiresConfirmation`, `isCancellable`, `resultShape`, and
   (for the three site ops) `sideEffect` values. This is a value table, not a
   behavioral cross-check — it guards against typos and missed updates, but cannot by
   itself prove the intent's runtime behavior matches. The two limits above are why.

When #239 adds confirmation to `EditContentIntent`, group 6's value table must be
updated to `requiresConfirmation: true` for `edit-content` — a deliberate manual
checkpoint, since confirmation isn't behaviorally enforced. `isCancellable` is
likewise a declared field only (real cancellation is #238's scope); its values mirror
the `CancellableIntent` conformances in source — deploy, backup, audit, add-page,
add-post, edit (the six `LongRunning`/`Cancellable` intents) are `true`; open,
search, status, preview are `false`.

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
| Deploy/edit operations marked as requiring confirmation | Deploy `requiresConfirmation: true` (declared, value-asserted in group 6); edit reflects current `false`, flips to `true` with #239 at the documented manual checkpoint |
| Read-only operations marked as non-destructive | `sideEffect: .readOnly` for audit/open/search/status/preview; content reads (search/status/preview) behaviorally enforced by content-mutation agreement (group 5), site `audit` value-asserted (group 6) |
| Descriptors cover the current Siri-facing operations | Coverage test (anchor subset) |
| Tests catch missing descriptors for new Siri-facing intents/tools | Coverage + anchor-sync guard tests |

## Build / verification

`swift test --package-path .` (filtered to `AnglesiteIntentsTests`). Both schemes
(`Anglesite`, `AnglesiteMAS`) must build — the new types are plain value types in
`AnglesiteIntents`, no target-specific gating.
