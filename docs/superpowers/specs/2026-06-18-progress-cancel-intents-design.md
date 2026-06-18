# Progress reporting + cancellation for long-running intents

**Issue:** #238 — Siri AI: add progress reporting and cancellation for long-running intents
**Date:** 2026-06-18
**Status:** Approved (design)

## Goal

Long-running App Intents (deploy, backup, audit, create page/post, natural-language
edit) currently conform to `LongRunningIntent`/`CancellableIntent` but do nothing with
either capability: their `performBackgroundTask(onCancel:)` closures are empty, several
command actors ignore `Task.isCancelled`, `MCPClient.callTool` cannot be interrupted at
all, and no structured progress is emitted anywhere. This work makes cancellation
actually stop in-flight work (including the MCP layer) and emits structured progress
milestones from the command actors, surfaced both in the app UI and through the system
App Intents progress API.

## Constraints (from the issue + CLAUDE.md)

- **Command actors stay the source of truth; intents stay thin adapters.** Progress and
  cancellation logic live in `AnglesiteCore`, not in the intent structs.
- **Acceptance criterion (hard):** canceling a Siri/Shortcuts operation *before* the MCP
  call must prevent the MCP call.
- **CI-testable logic lives in `AnglesiteCore`.** Hosted app-target tests don't run on
  CI's macOS-15 runner, so all deterministic coverage targets `AnglesiteCore` where
  `swift test` runs.
- **macOS-27-only App Intents symbols stay behind `#if compiler(>=6.4)`** (matches the
  existing `LongRunningIntent`/`CancellableIntent` conformances; CI runs Swift 6.3).

## Current state (verified by exploration)

- **Intents already conform** to `LongRunningIntent`/`CancellableIntent` (gated
  `#if compiler(>=6.4)`): `DeploySiteIntent`, `BackupSiteIntent`, `AuditSiteIntent`
  (`SiteIntents.swift`), `AddPageIntent`, `AddPostIntent` (`ContentIntents.swift`),
  `EditContentIntent` (`EditContentIntent.swift`). The comment at `SiteIntents.swift:163`
  confirms the protocol chain `LongRunningIntent → ProgressReportingIntent → AppIntent`,
  so the system progress surface is already reachable from these types.
- **`onCancel: { _ in }` closures are empty** in every `performBackgroundTask` call site.
- **Command-actor cancellation is inconsistent:** `DeployCommand` and `AuditCommand` wrap
  their subprocess wait in `withTaskCancellationHandler { waitForExit } onCancel: { terminate }`
  (SIGTERM on cancel); `BackupCommand` has none; the audit runner loop has no per-runner
  `Task.isCancelled` checks.
- **`MCPClient.callTool` is not cancellable.** `sendRequest` registers its continuation in
  `pending[id]` and resolves it via `failPending(id:error:)` from three paths (response,
  timeout, send-error). There is no `Task.isCancelled` path. This is why
  `ContentOperations.create` (create page/post) and `EditContentIntent` (via
  `MCPApplyEditRouter`) cannot cancel — and why `EditContentIntent` carries a documented
  "patch can still land after cancellation" limitation.
- **No structured progress type exists.** Progress is only implicitly observable via
  `LogCenter` text streams (consumed by `DeployModel`'s `Phase` enum in the UI).

## Design

### ① Milestone model (`AnglesiteCore`)

A new `Sendable` value type emitted at phase boundaries:

```swift
public struct OperationProgress: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case deploy, backup, audit, createContent, edit
    }
    public let kind: Kind
    public let phase: String        // stable milestone id, e.g. "building"
    public let label: String        // human/Siri-readable, e.g. "Building site…"
    public let fraction: Double?     // optional 0...1 when determinable; nil = indeterminate
}
```

Phases are anchored to the real code paths, not invented:

| Operation | Milestones (in order) |
|-----------|----------------------|
| deploy    | `preflightScan` → `building` → `deploying` → `finalizing` |
| backup    | `staging` → `committing` → `pushing` |
| audit     | `building` → `running` (per runner) → `finalizing` |
| createContent | `resolvingRuntime` → `callingPlugin` → `finalizing` |
| edit      | `resolvingRouter` → `applying` |

`fraction` is populated only where a real denominator exists (e.g. audit
runner *i of n*); otherwise `nil` (indeterminate). No fabricated percentages.

**Delivery — callback, not AsyncStream.** A handler is threaded through the operation
service methods as an additive, defaulted parameter:

```swift
public typealias ProgressHandler = @Sendable (OperationProgress) -> Void

// SiteOperationsService
func deploy(site: SiteStore.Site, onProgress: ProgressHandler?) async -> DeployCommand.Result
func backup(site: SiteStore.Site, onProgress: ProgressHandler?) async -> BackupCommand.Result
func audit(site: SiteStore.Site, onProgress: ProgressHandler?) async -> AuditCommand.Result

// ContentOperationsService
func createPage(siteID:, name:, route:, onProgress: ProgressHandler?) async -> ContentCreateResult
func createPost(siteID:, title:, collection:, slug:, onProgress: ProgressHandler?) async -> ContentCreateResult
```

The existing zero-`onProgress` signatures are preserved via defaulted parameters (or thin
overloads) so current call sites and tests keep compiling. The command actors invoke the
handler at each milestone boundary. Rationale for a callback over `AsyncStream`: it's
synchronous, requires no extra task/continuation plumbing, and is trivially captured by a
fake in tests.

Consumers of the handler:
- **App UI models** (`DeployModel`, `BackupModel`, …) pass their own handler to drive
  on-screen phase/progress state (additive to the existing `LogCenter` subscription).
- **Intents** pass an adapter (workstream ③).
- **Tests** pass a capturing handler and assert the emitted milestone sequence.

### ② Cancellation

**MCP layer (the deepest part).** Wrap the `withCheckedThrowingContinuation` in
`MCPClient.sendRequest` with `withTaskCancellationHandler`; its `onCancel` calls
`failPending(id:, error: CancellationError())`. This mirrors the existing `timeoutTask`
resolution path and adds a *fourth* resolution path (cancellation) with no new concurrency
primitives. Net effect: every `callTool` becomes interruptible mid-request, fixing both
`ContentOperations.create` and the documented `EditContentIntent` limitation. We reuse
Swift's `CancellationError` (decision (b)) — no new `MCPError.cancelled` case — so it maps
uniformly with `Task.checkCancellation()`.

**Pre-call guard (satisfies the hard acceptance criterion).** Immediately before invoking
`callTool`, add `try Task.checkCancellation()` in `ContentOperations` and
`MCPApplyEditRouter`. This prevents the MCP call when cancellation arrives *before* the
call, independent of in-flight support. The `EditContentIntent` known-limitation comment
is removed once both this guard and the in-flight path land.

**Command actors.** Add the `withTaskCancellationHandler { waitForExit } onCancel: { terminate }`
wrap to `BackupCommand` (matching `DeployCommand`/`AuditCommand`), and add
`Task.isCancelled` checkpoints to the `AuditCommand` runner loop so a cancel between
runners stops further work.

**Friendly dialog mapping.** `CancellationError` thrown out of an operation is caught at
the intent boundary and mapped to a "Cancelled the deploy of *X*." style dialog (per
operation) rather than surfacing as a generic failure. New `ContentDialogs`/`SiteOperations`
dialog helpers, unit-tested like the existing dialog formatters.

### ③ System-progress adapter (`AnglesiteIntents`)

A thin, `#if compiler(>=6.4)`-gated forwarder that maps each `OperationProgress` into the
intent's `ProgressReportingIntent` reporter. The exact reporter symbol/API is verified
against the macOS 27 SDK at implementation time; on Xcode 26.3 the whole adapter compiles
out, exactly like the existing conformances. The empty `onCancel: { _ in }` closures are
replaced with the progress wiring (and, where the system surfaces a cancel reason, mapped
into the friendly dialog path).

Intents remain thin: they construct the adapter handler, pass it to the operation service,
and translate the `Result`/`CancellationError` into a dialog. No milestone logic lives in
the intent layer.

## Testing

All deterministic coverage targets `AnglesiteCore` (runs on CI):

- **Cancellation tests:** spawn the operation in a `Task`, cancel it, and assert:
  - the command actor calls `supervisor.terminate(...)` (Deploy/Backup/Audit subprocess
    paths);
  - `MCPClient.callTool` throws `CancellationError` when its task is cancelled mid-request
    (using a fake/stub transport that never replies);
  - the pre-call `Task.checkCancellation()` guard prevents `callTool` from being invoked at
    all when cancellation precedes the call (the hard acceptance criterion).
- **Progress-sequence tests:** run each operation with a capturing handler and assert the
  exact ordered milestone list per operation.

Intent-layer tests (in `AnglesiteIntentsTests`, gated `#if compiler(>=6.4)`):

- `FakeOperations` is extended to (a) capture the `onProgress` handler and replay a
  scripted milestone sequence, and (b) optionally throw `CancellationError`.
- Assert the cancelled path maps to the friendly per-operation dialog.

## Out of scope

- Changing the natural-language edit op semantics (still `apply-instruction`, plugin's
  responsibility).
- New UI surfaces beyond feeding the existing `@Observable` models a progress handler.
- Removing the `#if compiler(>=6.4)` guards (tracked separately in #128).

## Files touched (anticipated)

- **New:** `Sources/AnglesiteCore/OperationProgress.swift`
- `Sources/AnglesiteCore/SiteOperationsService.swift`, `SiteOperations.swift`
- `Sources/AnglesiteCore/ContentOperationsService.swift`, `ContentOperations.swift`
- `Sources/AnglesiteCore/DeployCommand.swift`, `BackupCommand.swift`, `AuditCommand.swift`
- `Sources/AnglesiteCore/MCPClient.swift`, `MCPApplyEditRouter.swift`
- `Sources/AnglesiteIntents/SiteIntents.swift`, `ContentIntents.swift`,
  `EditContentIntent.swift` (+ a new progress-adapter file)
- `Sources/AnglesiteApp/DeployModel.swift`, `BackupModel.swift` (consume the handler)
- Tests under `Tests/AnglesiteCoreTests/` and `Tests/AnglesiteIntentsTests/`
