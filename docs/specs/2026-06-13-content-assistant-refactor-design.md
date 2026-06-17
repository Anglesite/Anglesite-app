# ContentAssistant event reconciliation (C.2 / C.3)

**Date:** 2026-06-13
**Issues:** #152 (C.2 — `ClaudeAssistant` wrapper), #153 (C.3 — `ChatModel` → `ContentAssistant`)
**Parent:** #134 (Siri AI Phase C — Foundation Models)
**Depends on:** C.1 (`ContentAssistant` protocol, landed in `fd6568b`)

## Problem

C.1 introduced `ContentAssistant` (`Sources/AnglesiteCore/ContentAssistant.swift`), a
provider-agnostic surface whose streaming method `generate(prompt:context:)` yields **plain
`String` chunks**. C.3 asks `ChatModel` to depend on `any ContentAssistant` instead of the
concrete `ClaudeAgent`, framed as a "mechanical seam swap, no behavior change."

That framing under-specifies one thing: `ChatModel` consumes `ClaudeAgent`'s **rich** event
stream — `AsyncStream<ClaudeAgent.Event>` carrying tool-use, tool-result, token usage, and
process-exit — in a ~50-line `handle(_:)`. `ContentAssistant.generate()` deliberately flattens
all of that to text (the protocol's own doc comment defers reconciliation to "the C.3 refactor").
Swapping `ChatModel` to `generate()` as-is would **drop tool-use rendering** — a real behavior
regression, not a no-op.

A second correction: there are **no `ChatModelTests`**. `ChatModel` is in the `AnglesiteApp`
target, which `swift test` does not cover (only `AnglesiteCore` / `AnglesiteBridge`). The C.3
criterion "all `ChatModelTests` pass unchanged" refers to tests that do not exist. C.3 is
verified by **build**, not test run.

## Approach (chosen)

Introduce a provider-agnostic **event** stream and a **refinement** protocol, so `ChatModel`
keeps consuming structured events — just provider-agnostic ones. The base `ContentAssistant`
stays text-only for tool-only backends (alt-text, summaries — #157).

### 1. Agnostic event surface — `Sources/AnglesiteCore/ConversationalAssistant.swift` (new)

`AssistantEvent` mirrors exactly the `ClaudeAgent.Event` cases `ChatModel.handle` consumes —
nothing the consumer ignores leaks in:

```swift
public enum AssistantEvent: Sendable, Equatable {
    case started(model: String?, toolNames: [String])      // ← .sessionStarted
    case textDelta(String)                                  // ← .assistantText (messageID dropped — unused)
    case thinking(String)                                   // ← .assistantThinking
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(id: String, content: String, isError: Bool)
    case turnComplete(AssistantUsage?)                      // ← .turnComplete (stopReason dropped — unused)
    case failed(message: String)                            // ← .streamError
    case cancelled
    case backendExited(code: Int32)                         // ← .processExited
}

public struct AssistantUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double?
    public let durationMs: Int?
}
```

The mapping is intentionally lossy: `ChatModel` already ignores `sessionStarted`,
`assistantThinking`, the `messageID` on text, and `stopReason`. Modeling the event around what
the consumer *uses* (not what Claude *emits*) keeps the surface honest for a future Foundation
Models backend.

### 2. Refinement protocol — same file

```swift
public protocol ConversationalAssistant: ContentAssistant {
    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent>
    func cancel() async
    func resetSession() async
}
```

A refinement (not new methods on the base) so tool-only backends needn't implement a
conversational loop. `ChatModel`'s dependency type is `any ConversationalAssistant` — this is a
deliberate, correctness-driven deviation from #153's literal `any ContentAssistant`.

`AssistantError.unsupported(String)` (new, in Core) is thrown by backends that don't implement an
optional capability (e.g. Claude + `generateStructured`).

### 3. `ClaudeAssistant` (C.2) — `Sources/AnglesiteCore/ClaudeAssistant.swift`, `#if !ANGLESITE_MAS`

Wraps `ClaudeAgent`, conforms to `ConversationalAssistant`:

- `init(siteID:siteDirectory:)` constructs the wrapped `ClaudeAgent`; a test init injects one.
- `converse(prompt:context:)` forwards `prompt` to `agent.send(prompt:)` and maps each
  `ClaudeAgent.Event → AssistantEvent` 1:1. The per-call `context` site fields are already baked
  into the agent at construction, so behavior is identical to today.
- `cancel()` / `resetSession()` forward to the agent.
- Base `ContentAssistant` conformance: `generate()` adapts `converse` to text-only chunks
  (collect `.textDelta`, surface `.failed` as a thrown error); `generateStructured()` throws
  `AssistantError.unsupported`; `capabilities` = streaming + tools, `structuredOutput:false`,
  `vision:false`, `providerName:"Claude"`.

This is the one unit with real automated coverage: **`ClaudeAssistantTests`** in
`AnglesiteCoreTests`, reusing `ClaudeAgent`'s existing fixture launcher to assert the
event-mapping passthrough.

### 4. `ChatModel` refactor (C.3) — `Sources/AnglesiteApp/ChatModel.swift`

- `private let agent: ClaudeAgent` → `private let assistant: any ConversationalAssistant`.
- `consumeAgentStream` calls `assistant.converse(prompt:context:)`; builds the per-call
  `AssistantContext` from the model's known `siteID`/`siteDirectory` (current-page / selected
  element stay `nil` for now — no behavior change vs. today's `send(prompt:)`).
- `handle(_:)` switches over `AssistantEvent` (a near-mechanical case rename; the `.started` and
  `.thinking` arms stay `break`, matching today).
- `cancel()` / `clear()` call `assistant.cancel()` / `assistant.resetSession()`.

### 5. MAS gating (chosen: target-agnostic now, per #153)

The `#if !ANGLESITE_MAS` guard shrinks to wrap **only** the `ClaudeAssistant` *construction*, not
`ChatModel` itself:

- `ChatModel` gets a general injecting init `init(..., assistant: any ConversationalAssistant)`
  available on **both** targets (used by future MAS + any test).
- A DevID-only convenience init `#if !ANGLESITE_MAS init(siteID:siteDirectory:...)` constructs the
  `ClaudeAssistant`.
- The `SiteWindow` chat UI that constructs `ChatModel` remains `#if !ANGLESITE_MAS`, so on MAS
  `ChatModel` compiles but is not yet constructed (dead until #155 `FoundationModelAssistant` /
  #159 MAS chat enablement — accepted trade-off).
- **Audit** `ChatModel`'s other dependencies (`ChatHistoryStore`, `AnnotationFeed`,
  `AnnotationResolver`, `UndoCommand`) for MAS-compilability as part of this step; gate anything
  that is genuinely DevID-only.

## Out of scope

- Actually enabling a MAS chat backend (#155 `FoundationModelAssistant`, #159 MAS chat UI).
- Using `AssistantContext.currentPageRoute` / `selectedElementSelector` to enrich the prompt —
  the wrapper accepts them but does not yet act on them (future onscreen-edit work).
- Vision / structured-output on the Claude path.

## Verification

- `swift test --filter ClaudeAssistantTests` (+ existing `ClaudeAgentTests`) — green.
- `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` — DevID
  app links with the new seam.
- `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build` —
  confirms `ChatModel` compiles target-agnostic on MAS.
- Manual: chat a prompt that triggers a tool call (e.g. "deploy my site") on the DevID build;
  confirm tool-use rows, streamed text, and turn telemetry render exactly as before.

## Files

| File | Change |
|---|---|
| `Sources/AnglesiteCore/ConversationalAssistant.swift` | **new** — `AssistantEvent`, `AssistantUsage`, `ConversationalAssistant`, `AssistantError` |
| `Sources/AnglesiteCore/ClaudeAssistant.swift` | **new** — wraps `ClaudeAgent`, `#if !ANGLESITE_MAS` |
| `Sources/AnglesiteApp/ChatModel.swift` | seam swap to `any ConversationalAssistant`; `handle` over `AssistantEvent`; init split + guard shrink |
| `Tests/AnglesiteCoreTests/ClaudeAssistantTests.swift` | **new** — event-mapping passthrough |
