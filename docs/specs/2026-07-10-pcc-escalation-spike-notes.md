# PCC escalation feasibility spike — findings (2026-07-10)

**Task:** Task 1 of the design-interview conversation plan (issue #464 line of work). Investigation
only — no code changed. Goal: verify whether the on-device `FoundationModels` framework exposes any
caller-selectable Private Cloud Compute (PCC) path, before Task 4 of the plan builds against it.

**Existing internal claim under test** (`Sources/AnglesiteCore/FoundationModelAssistant.swift:9-13`):

> The public `FoundationModels` framework is **on-device**. There is no caller-selectable Private
> Cloud Compute session; PCC is used transparently by some system APIs. `.privateCloudCompute` is
> therefore *modeled* here so future call sites can express intent, but **v1 backs it with the same
> on-device session**.

## Outcome (up front)

**PCC-reachable — the existing code comment is now stale, not confirmed.** The macOS 27 /
Xcode 27 SDK (Xcode-beta.app, build 27A5209h, targeting macOS 26A5378j — the toolchain this project
already builds against per CLAUDE.md) ships a genuine, app-facing
`PrivateCloudComputeLanguageModel` class in `FoundationModels`, introduced at
`@available(iOS 27.0, macOS 27.0, *)`. It is a real API, not a rumor or WWDC-notes inference — the
module's compiled Swift interface was synthesized directly from the installed SDK and inspected
below. See "Decision gate" for what this changes and does not change for the plan.

## Step 1: check the public API surface for PCC symbols

The brief's exact command uses `swift-ide-test`, which does not exist in this Xcode 27 beta
toolchain:

```
$ DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift-ide-test \
  -print-module -module-to-print=FoundationModels -source-filename x \
  -target arm64-apple-macos27.0 2>/dev/null | grep -i "cloud\|pcc\|remote"
```
```
xcrun: error: sh -c '.../xcodebuild -sdk .../MacOSX27.0.sdk -find swift-ide-test 2> /dev/null' failed
xcrun: error: unable to find utility "swift-ide-test", not a developer tool or in PATH
```

`swift-ide-test` has been removed from this toolchain's `usr/bin` (it ships `swift-symbolgraph-extract`,
`swift-synthesize-interface`, etc. instead). Substituted the toolchain's `swift-synthesize-interface`
(the direct successor for this exact purpose — printing a module's public Swift interface from a
binary SDK module) to get equivalent output:

```
$ DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  /Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-synthesize-interface \
  -sdk /Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk \
  -target arm64-apple-macos27.0 -module-name FoundationModels \
  -o /tmp/FoundationModels.swiftinterface
$ echo $?
0
$ wc -l /tmp/FoundationModels.swiftinterface
9210 /tmp/FoundationModels.swiftinterface
```

Grep for cloud/pcc/remote symbols in the synthesized interface:

```
$ grep -ni "cloud\|pcc\|remote" /tmp/FoundationModels.swiftinterface
```

Relevant excerpt (full match list is ~90 lines, all inside one type's declaration):

```swift
/// A variant of Apple Foundation Models that runs on Private Cloud Compute to provide enhanced
/// capabilities while maintaining privacy guarantees.
///
/// To use the server-based model that powers Apple Intelligence, you change a single line of code
/// that you apply when creating your ``LanguageModelSession``.
///
/// ```swift
/// // Create a session with the server-side model.
/// let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
/// let response = try await session.respond(to: "Analyze this document...")
/// ```
///
/// Before you use the model, you'll need to verify its ``availability``. Model
/// availability depends on device factors like:
///
/// * The device must support Apple Intelligence.
/// * Apple Intelligence must be turned on in Settings.
///
/// > Important: To develop with PCC you must meet certain eligibility requirements.
/// To learn more and request access to the manage entitlement, sign in to your Developer
/// account and complete the
/// [entitlement request form](https://developer.apple.com/contact/request/private-cloud-compute/).
@available(iOS 27.0, macOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
final public class PrivateCloudComputeLanguageModel : Sendable {
    @objc deinit
}

extension PrivateCloudComputeLanguageModel {
    final public var availability: PrivateCloudComputeLanguageModel.Availability { get }
    final public var quotaUsage: PrivateCloudComputeLanguageModel.QuotaUsage { get }
    final public var isAvailable: Bool { get }
}

extension PrivateCloudComputeLanguageModel {
    /// Creates a new Private Cloud Compute language model instance.
    public convenience init()
}

extension PrivateCloudComputeLanguageModel {
    @frozen public enum Availability : Equatable, Sendable {
        case available
        case unavailable(PrivateCloudComputeLanguageModel.Availability.UnavailableReason)
    }
}

extension PrivateCloudComputeLanguageModel : nonisolated Observable {}

extension PrivateCloudComputeLanguageModel : LanguageModel {
    final public var capabilities: LanguageModelCapabilities { get }
    final public var executorConfiguration: PrivateCloudComputeLanguageModel.Executor.Configuration { get }
}

extension PrivateCloudComputeLanguageModel {
    /// Returns the maximum context size (in tokens) supported by the model.
    nonisolated(nonsending) final public var contextSize: Int { get async throws }
}

extension PrivateCloudComputeLanguageModel {
    public struct Executor : LanguageModelExecutor { /* ... */ }
}

extension PrivateCloudComputeLanguageModel {
    /// Errors that may occur when using Private Cloud Compute.
    public enum Error : Error, LocalizedError {
        case networkFailure(PrivateCloudComputeLanguageModel.Error.NetworkFailure)
        case quotaLimitReached(PrivateCloudComputeLanguageModel.Error.QuotaLimitReached)
        case serviceUnavailable(PrivateCloudComputeLanguageModel.Error.ServiceUnavailable)
    }

    /// The usage quota state for a Private Cloud Compute language model.
    ///
    /// Quotas are orthogonal to a model's availability — a model can be available even after its
    /// usage limit has been reached.
    public struct QuotaUsage : Sendable {
        public var status: PrivateCloudComputeLanguageModel.QuotaUsage.Status
        public var limitIncreaseSuggestion: PrivateCloudComputeLanguageModel.QuotaUsage.LimitIncreaseSuggestion?
        public var resetDate: Date?
    }
}
```

Confirmed `PrivateCloudComputeLanguageModel` genuinely satisfies `LanguageModel`, and that
`LanguageModelSession` has a generic initializer that accepts it (not just the `SystemLanguageModel`-typed
convenience initializers):

```
$ grep -n "public convenience init<Failure>(model: some LanguageModel" /tmp/FoundationModels.swiftinterface
4205:    public convenience init<Failure>(model: some LanguageModel, tools: [any Tool] = [], @InstructionsBuilder instructions: () throws(Failure) -> Instructions) throws(Failure) where Failure : Error
```

So the doc comment's own sample code (`LanguageModelSession(model: PrivateCloudComputeLanguageModel())`)
is not aspirational marketing copy — it type-checks against the declared API surface.

## Step 2: public developer documentation / WWDC session search

**Not performed with independent evidence.** This environment has no `WebSearch`/`WebFetch` tool
available to this agent, so I cannot fetch developer.apple.com/documentation/foundationmodels or
WWDC session transcripts live. I am not fabricating a documentation search. Everything above and
below is derived solely from the doc comments embedded in the installed Xcode 27 beta SDK's compiled
module (which does typically mirror what ends up on developer.apple.com, but that mirroring itself
is unverified here). If a live web check is wanted for confirmation, this step should be re-run with
a `WebFetch`-capable session against
`https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel`.

## Step 3: probe `SystemLanguageModel` for a size/tier selector

```
$ grep -n "class SystemLanguageModel\|struct SystemLanguageModel" /tmp/FoundationModels.swiftinterface
6469:final public class SystemLanguageModel : Sendable {
```

`SystemLanguageModel` itself exposes only a `UseCase` selector (`.general`, `.contentTagging`) — no
size/tier axis:

```swift
public struct UseCase : Sendable, Equatable {
    /// A use case for general prompting. This is the default use case for the base version of the model.
    public static let general: SystemLanguageModel.UseCase
    /// A use case for content tagging.
    public static let contentTagging: SystemLanguageModel.UseCase
}
```

and a plain `contextSize: Int` (synchronous, on-device):

```swift
extension SystemLanguageModel {
    /// Returns the maximum context size (in tokens) supported by the model.
    @backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4)
    final public var contextSize: Int { get }
}
```

So there is no "large on-device model" tier hidden inside `SystemLanguageModel` — the only larger
context window available is the separate `PrivateCloudComputeLanguageModel` type (async `contextSize`,
consistent with it being a network-backed model rather than an in-process one).

## Decision gate

**PCC-reachable**, with an important caveat: it is not *freely* reachable. Concretely:

- `PrivateCloudComputeLanguageModel()` is a genuine, public, documented, `Sendable`,
  `Observable`-conforming class that conforms to the same `LanguageModel` protocol
  `SystemLanguageModel` conforms to, and `LanguageModelSession` has a generic initializer
  (`init<Failure>(model: some LanguageModel, ...)`) that accepts it directly — not a private/SPI
  symbol, not something only reachable via a system-only entry point.
- It requires `iOS 27.0 / macOS 27.0`, which matches this project's minimum deployment target
  (`Package.swift` declares `.macOS("27.0")`), so no additional OS-version bump would be needed.
- **It is gated behind a manual Apple entitlement request**, per the type's own doc comment: *"To
  develop with PCC you must meet certain eligibility requirements. To learn more and request access
  to the manage entitlement, sign in to your Developer account and complete the [entitlement request
  form]."* This is the same shape as other restricted entitlements (e.g. NFC tag-writing,
  driver extensions) — approval is not guaranteed, is out of this repo's control, and would need to
  be requested and granted before any code depending on it could ship, even in TestFlight.
- It also carries its own **usage quota** (`QuotaUsage`, `.limitReached` status,
  `limitIncreaseSuggestion`) and **availability preconditions** (device supports Apple Intelligence,
  Apple Intelligence enabled in Settings) — so even once entitled, it is not an unconditionally
  available "just ask for more tokens" path; call sites must handle `.unavailable` and quota-exhausted
  states as first-class outcomes, same as this codebase's existing `SystemLanguageModel.availability`
  handling pattern.

### Two next-step paths, per the brief's decision gate

- **If PCC-reachable (this spike's actual finding):** Task 4 can build against the real
  `PrivateCloudComputeLanguageModel` API — `import FoundationModels`, construct
  `PrivateCloudComputeLanguageModel()`, gate on `.isAvailable`/`.availability` and `.quotaUsage`
  before use, and pass it to `LanguageModelSession(model:)`'s generic initializer instead of the
  `SystemLanguageModel`-typed convenience initializer `FoundationModelAssistant` uses today. This
  requires (a) actually filing and getting approved the PCC entitlement request at
  `developer.apple.com/contact/request/private-cloud-compute/` — an out-of-band, non-code
  prerequisite with unknown timeline — and (b) designing quota/availability fallback behavior (revert
  to the on-device session, surface a user-facing message) for when PCC is entitled-but-unavailable
  or entitled-but-quota-exhausted. Given the entitlement is not yet requested/granted, Task 4 should
  **not** assume PCC is usable by default; it should be built as an optional escalation path behind a
  capability check that degrades gracefully to the on-device session, exactly as `FoundationModelTier`
  already models it structurally.
- **If PCC-not-reachable:** (documented for completeness, since the brief asked for both paths, even
  though this is not what was found) Task 4 would implement deterministic context-budget escalation
  instead — chunk/summarize grounding prompts deterministically when they would exceed the 4,096-token
  budget, rather than claim a larger model is available.

Given the entitlement-gated nature of the real finding, the **pragmatic recommendation for this
plan** is closer to the second path in the near term: implement Task 4 as deterministic
context-budget management now (no entitlement dependency, ships immediately), and track the real
`PrivateCloudComputeLanguageModel` integration as a separate, explicitly-gated follow-up once the PCC
entitlement request has actually been filed and approved. This avoids blocking the design-interview
feature on an Apple approval process with no committed timeline.

### `FoundationModelTier` doc comment

`Sources/AnglesiteCore/FoundationModelAssistant.swift:9-13`'s comment ("There is no caller-selectable
Private Cloud Compute session") is now **factually stale** as of the macOS 27 / Xcode 27 SDK: a
caller-selectable session does exist as public API, gated by a separate Apple entitlement approval
rather than by API availability. The comment should be corrected (in a follow-up code change, not in
this investigation-only task) to state:

- `PrivateCloudComputeLanguageModel` is real, public API (cite this spike/doc), conforming to
  `LanguageModel` and usable via `LanguageModelSession(model:)`.
- `.privateCloudCompute` remains **unimplemented in this codebase**, not because no API exists, but
  because (a) it requires a manually-requested-and-approved Apple entitlement this project has not
  yet obtained, and (b) it introduces network dependency, quota, and availability-fallback complexity
  not yet designed. v1 continues to back `.privateCloudCompute` with the same on-device session until
  that entitlement/design work happens.

## Toolchain note for future spikes

`swift-ide-test` is not present in this Xcode 27 beta's toolchain bin (`Toolchains/XcodeDefault.xctoolchain/usr/bin`
has `swift-symbolgraph-extract` and `swift-synthesize-interface` but not `swift-ide-test`). Use
`swift-synthesize-interface -sdk <SDK> -target <triple> -module-name <Module> -o <out>` as the
equivalent module-interface-printing tool on this toolchain going forward.
