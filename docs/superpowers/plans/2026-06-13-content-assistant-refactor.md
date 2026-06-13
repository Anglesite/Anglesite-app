# ContentAssistant Event Reconciliation (C.2/C.3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ChatModel` depend on a provider-agnostic `ConversationalAssistant` (wrapping `ClaudeAgent` via a new `ClaudeAssistant`) instead of `ClaudeAgent` directly, preserving all tool-use/usage rendering and making `ChatModel` compile on both build targets.

**Architecture:** A new `AssistantEvent` enum mirrors exactly the `ClaudeAgent.Event` cases `ChatModel` consumes. A `ConversationalAssistant: ContentAssistant` refinement adds `converse`/`cancel`/`resetSession`. `ClaudeAssistant` (DevID-only) wraps `ClaudeAgent` and maps its events 1:1. `ChatModel` switches to `any ConversationalAssistant` and its `#if !ANGLESITE_MAS` guard shrinks to only the `ClaudeAssistant` construction.

**Tech Stack:** Swift 6.4 / Xcode 27, SwiftPM (`AnglesiteCore`), Swift Testing + XCTest, `xcodebuild` for the app targets.

**Spec:** `docs/superpowers/specs/2026-06-13-content-assistant-refactor-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/AnglesiteCore/ConversationalAssistant.swift` | **new** — `AssistantEvent`, `AssistantUsage`, `AssistantError`, `ConversationalAssistant` protocol |
| `Sources/AnglesiteCore/ClaudeAssistant.swift` | **new** — wraps `ClaudeAgent`; `ClaudeAgent.Event → AssistantEvent` mapping; `#if !ANGLESITE_MAS` |
| `Tests/AnglesiteCoreTests/ClaudeAssistantTests.swift` | **new** — event-mapping passthrough via a fixture launcher |
| `Sources/AnglesiteApp/ChatModel.swift` | seam swap to `any ConversationalAssistant`; store `siteID`; `handle` over `AssistantEvent`; guard shrink |
| `Sources/AnglesiteApp/SiteWindow.swift` | construction call site (line ~343) — thread `siteID` (already passed) |
| `Sources/AnglesiteApp/ChatView.swift` | preview construction (line ~389) — no signature change (uses convenience init) |

---

## Task 1: Agnostic event surface + refinement protocol

Pure type declarations — no behavior, so this task is verified by **build**, not a unit test. The behavior (mapping) is TDD'd in Task 2.

**Files:**
- Create: `Sources/AnglesiteCore/ConversationalAssistant.swift`

- [ ] **Step 1: Create the file with the event types and protocol**

```swift
import Foundation

/// A provider-agnostic streaming event from a ``ConversationalAssistant``.
///
/// Mirrors exactly the subset of `ClaudeAgent.Event` that `ChatModel` consumes — the cases the
/// chat UI ignores (`messageID` on text, `stopReason` on completion) are intentionally dropped so
/// a non-Claude backend (Foundation Models, #155) can populate the same surface without faking a
/// subprocess. See `docs/superpowers/specs/2026-06-13-content-assistant-refactor-design.md`.
public enum AssistantEvent: Sendable, Equatable {
    /// First event of a turn: the resolved model and the tool names available this turn.
    case started(model: String?, toolNames: [String])
    /// A chunk of streamed assistant text. Appended to the in-flight message.
    case textDelta(String)
    /// An assistant "thinking" block. The chat panel captures but does not render these.
    case thinking(String)
    /// The assistant invoked a tool; the result arrives later as `.toolResult` (paired by `id`).
    case toolUse(id: String, name: String, input: JSONValue)
    /// A tool returned its content. `isError` flags a tool-reported failure.
    case toolResult(id: String, content: String, isError: Bool)
    /// Terminal-ish event carrying turn telemetry (token usage, cost, duration), if available.
    case turnComplete(AssistantUsage?)
    /// The backend reported an in-band error string (distinct from a thrown setup error).
    case failed(message: String)
    /// The turn was cancelled by the caller.
    case cancelled
    /// The backing process/session exited with this OS code (`0` is clean).
    case backendExited(code: Int32)
}

/// Token/cost telemetry for one completed turn.
public struct AssistantUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double?
    public let durationMs: Int?

    public init(inputTokens: Int, outputTokens: Int, costUSD: Double? = nil, durationMs: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.durationMs = durationMs
    }
}

/// Errors thrown by a ``ContentAssistant`` when a requested capability isn't supported by the
/// backend (e.g. Claude cannot do FoundationModels guided generation).
public enum AssistantError: Error, Sendable, Equatable {
    case unsupported(String)
}

/// A ``ContentAssistant`` that also supports a multi-turn, tool-using conversation with a rich
/// event stream. `ChatModel` depends on this refinement (not the base `ContentAssistant`) because
/// it needs structured tool-use/usage events that the base `generate()` flattens to plain text.
public protocol ConversationalAssistant: ContentAssistant {
    /// Streams a full conversational turn as ``AssistantEvent`` values. The outer `async throws`
    /// covers setup failure (backend unavailable); in-band failures surface as `.failed`.
    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent>

    /// Terminates the in-flight turn, if any. No-op when nothing is running.
    func cancel() async

    /// Resets session/continuation state so the next `converse` starts a fresh conversation.
    func resetSession() async
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --package-path .`
Expected: builds cleanly (`Compiling AnglesiteCore ConversationalAssistant.swift`), no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteCore/ConversationalAssistant.swift
git commit -m "feat(core): AssistantEvent + ConversationalAssistant refinement (#153)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `ClaudeAssistant` wrapper (C.2) — TDD

**Files:**
- Create: `Sources/AnglesiteCore/ClaudeAssistant.swift`
- Test: `Tests/AnglesiteCoreTests/ClaudeAssistantTests.swift`

- [ ] **Step 1: Write the failing test**

This drives a `ClaudeAgent` with a fixture launcher (the same seam `ClaudeAgentTests` uses — `init(siteDirectory:pluginDirectory:launcher:)`), wraps it in `ClaudeAssistant`, and asserts the mapped `AssistantEvent` sequence. The fixture emits one of each meaningful line; the launcher reports a clean exit, so the agent appends `.processExited(code: 0)` → `.backendExited(code: 0)`.

```swift
import XCTest
@testable import AnglesiteCore

final class ClaudeAssistantTests: XCTestCase {

    /// Builds a ClaudeAgent whose launcher replays the given JSONL lines then exits `code`.
    private func makeAgent(lines: [String], exit code: Int32 = 0) -> ClaudeAgent {
        ClaudeAgent(
            siteDirectory: URL(fileURLWithPath: "/tmp/site"),
            pluginDirectory: nil,
            launcher: { _ in
                let stream = AsyncStream<String> { continuation in
                    for line in lines { continuation.yield(line) }
                    continuation.finish()
                }
                return ClaudeAgent.LaunchResult(
                    lines: stream,
                    cancel: {},
                    waitForExit: { code }
                )
            }
        )
    }

    func testConverseMapsClaudeEventsToAssistantEvents() async throws {
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus-4-8","tools":["Read"]}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hi"}]}}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"path":"a.md"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":false}]}}"#,
            #"{"type":"result","subtype":"success","usage":{"input_tokens":10,"output_tokens":5},"total_cost_usd":0.01,"duration_ms":1200}"#,
        ]
        let assistant = ClaudeAssistant(agent: makeAgent(lines: lines, exit: 0))
        let context = AssistantContext(siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/site"))

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "hello", context: context) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .started(model: "claude-opus-4-8", toolNames: ["Read"]),
            .textDelta("Hi"),
            .toolUse(id: "t1", name: "Read", input: .object(["path": .string("a.md")])),
            .toolResult(id: "t1", content: "ok", isError: false),
            .turnComplete(AssistantUsage(inputTokens: 10, outputTokens: 5, costUSD: 0.01, durationMs: 1200)),
            .backendExited(code: 0),
        ])
    }

    func testCapabilitiesReportClaudeProvider() {
        let caps = ClaudeAssistant(agent: makeAgent(lines: [])).capabilities
        XCTAssertEqual(caps.providerName, "Claude")
        XCTAssertTrue(caps.supportsStreaming)
        XCTAssertTrue(caps.supportsTools)
        XCTAssertFalse(caps.supportsStructuredOutput)
        XCTAssertFalse(caps.supportsVision)
    }
}
```

> Note: the exact JSONL field names (`tool_use_id`, `is_error`, `total_cost_usd`, `duration_ms`) must match what `ClaudeAgent.StreamJSONParser` parses. If a fixture line yields no/unexpected events, open `Sources/AnglesiteCore/ClaudeAgent.swift` (the `StreamJSONParser` section, ~line 200+) and align the fixture to the parser — do **not** change the parser.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter ClaudeAssistantTests`
Expected: FAIL to compile — `cannot find 'ClaudeAssistant' in scope`.

- [ ] **Step 3: Write `ClaudeAssistant`**

```swift
import Foundation

// Claude is the Developer ID backend only — the Mac App Store build has no `claude` CLI to shell
// out to. `ChatModel` itself is target-agnostic; only this construction is gated.
#if !ANGLESITE_MAS

/// Wraps ``ClaudeAgent`` behind ``ConversationalAssistant``, mapping the agent's rich
/// `ClaudeAgent.Event` stream to provider-agnostic ``AssistantEvent`` values 1:1.
///
/// Behaviour is identical to talking to `ClaudeAgent` directly: the agent is bound to one site at
/// construction, so the per-call ``AssistantContext`` site fields are not re-applied here (the
/// onscreen-edit work that uses `currentPageRoute` / `selectedElementSelector` is future scope).
public actor ClaudeAssistant: ConversationalAssistant {
    private let agent: ClaudeAgent

    /// Production: build an agent bound to `siteID` / `siteDirectory`.
    public init(siteID: String, siteDirectory: URL) {
        self.agent = ClaudeAgent(siteID: siteID, siteDirectory: siteDirectory)
    }

    /// Test/injecting: wrap a pre-built agent (typically with a fixture launcher).
    public init(agent: ClaudeAgent) {
        self.agent = agent
    }

    public nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true,
            supportsStructuredOutput: false,
            supportsVision: false,
            supportsTools: true,
            maxContextTokens: nil,
            providerName: "Claude"
        )
    }

    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        let upstream = try await agent.send(prompt: prompt)
        return AsyncStream { continuation in
            let task = Task {
                for await event in upstream {
                    continuation.yield(Self.map(event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel() async { await agent.cancel() }
    public func resetSession() async { await agent.resetSession() }

    // MARK: ContentAssistant (base) — text + structured

    public func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        let upstream = try await agent.send(prompt: prompt)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await event in upstream {
                    switch Self.map(event) {
                    case .textDelta(let text): continuation.yield(text)
                    case .failed(let message): continuation.finish(throwing: AssistantError.unsupported(message))
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if compiler(>=6.4)
    public func generateStructured<T: Generable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        throw AssistantError.unsupported("Claude backend does not support guided generation")
    }
    #endif

    // MARK: Mapping

    static func map(_ event: ClaudeAgent.Event) -> AssistantEvent {
        switch event {
        case .sessionStarted(_, let model, let toolNames):
            return .started(model: model, toolNames: toolNames)
        case .assistantText(_, let text):
            return .textDelta(text)
        case .assistantThinking(let text):
            return .thinking(text)
        case .toolUse(let id, let name, let input):
            return .toolUse(id: id, name: name, input: input)
        case .toolResult(let id, let content, let isError):
            return .toolResult(id: id, content: content, isError: isError)
        case .turnComplete(let usage, let costUSD, let durationMs, _):
            return .turnComplete(usage.map {
                AssistantUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, costUSD: costUSD, durationMs: durationMs)
            })
        case .streamError(let message):
            return .failed(message: message)
        case .cancelled:
            return .cancelled
        case .processExited(let code):
            return .backendExited(code: code)
        }
    }
}

#endif
```

> Note on `generateStructured`: the `#if compiler(>=6.4)` guard and the `Generable` bound must match the base `ContentAssistant` declaration in `ContentAssistant.swift` exactly. If the test bundle builds on Xcode 26.3 (Swift < 6.4), this method is absent from both protocol and conformance — no mismatch.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --filter ClaudeAssistantTests`
Expected: PASS (2 tests). If the mapping test fails on the `turnComplete` arm, confirm the fixture's `result` line carries `usage`, `total_cost_usd`, and `duration_ms` exactly as the parser expects.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ClaudeAssistant.swift Tests/AnglesiteCoreTests/ClaudeAssistantTests.swift
git commit -m "feat(core): ClaudeAssistant wraps ClaudeAgent as ConversationalAssistant (#152)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `ChatModel` seam swap (C.3, behaviour-preserving)

Swap `ChatModel`'s dependency from `ClaudeAgent` to `any ConversationalAssistant`, store `siteID`, and rewrite `handle` over `AssistantEvent`. **Keep the outer `#if !ANGLESITE_MAS` guard for now** — the MAS move is Task 4. Verified by the DevID app build (no `ChatModelTests` exist; `ChatModel` is in the app target).

**Files:**
- Modify: `Sources/AnglesiteApp/ChatModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (line ~343)
- Modify: `Sources/AnglesiteApp/ChatView.swift` (line ~389, preview)

- [ ] **Step 1: Replace the `agent` property + both initializers**

In `Sources/AnglesiteApp/ChatModel.swift`, replace the dependency declaration (currently `private let agent: ClaudeAgent` at line ~120) and the two initializers (lines ~141–159) with:

```swift
    private let siteID: String
    private let assistant: any ConversationalAssistant
```

```swift
    init(siteID: String, siteDirectory: URL, annotationFeed: AnnotationFeed? = nil, annotationResolver: AnnotationResolver? = nil, undoCommand: UndoCommand? = nil) {
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.assistant = ClaudeAssistant(siteID: siteID, siteDirectory: siteDirectory)
        self.history = ChatHistoryStore(siteDirectory: siteDirectory)
        self.annotationFeed = annotationFeed
        self.annotationResolver = annotationResolver
        self.undoCommand = undoCommand
    }

    /// Test/injecting initializer: supply the assistant (typically a fixture-backed `ClaudeAssistant`)
    /// and an optional history-store override.
    init(siteID: String, siteDirectory: URL, assistant: any ConversationalAssistant, history: ChatHistoryStore? = nil, annotationFeed: AnnotationFeed? = nil, annotationResolver: AnnotationResolver? = nil, undoCommand: UndoCommand? = nil) {
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.assistant = assistant
        self.history = history ?? ChatHistoryStore(siteDirectory: siteDirectory)
        self.annotationFeed = annotationFeed
        self.annotationResolver = annotationResolver
        self.undoCommand = undoCommand
    }
```

- [ ] **Step 2: Rewrite the stream consumer to use `converse`**

In `consumeAgentStream` (lines ~346–369), replace the stream type and `agent.send` call:

```swift
    private func consumeAgentStream(prompt: String) async {
        let stream: AsyncStream<AssistantEvent>
        do {
            let context = AssistantContext(siteID: siteID, siteDirectory: siteDirectory)
            stream = try await assistant.converse(prompt: prompt, context: context)
        } catch {
            inFlightAssistantIndex = nil
            isStreaming = false
            lastError = "couldn't start claude: \(error)"
            return
        }

        for await event in stream {
            handle(event)
        }

        if let idx = inFlightAssistantIndex {
            let finalMessage = messages[idx]
            persist(finalMessage)
        }
        inFlightAssistantIndex = nil
        isStreaming = false
    }
```

- [ ] **Step 3: Rewrite `handle` over `AssistantEvent`**

Replace the entire `handle(_ event: ClaudeAgent.Event)` method (lines ~371–429) with:

```swift
    private func handle(_ event: AssistantEvent) {
        guard let idx = inFlightAssistantIndex, messages.indices.contains(idx) else { return }
        switch event {
        case .started:
            // Surfaced as data only; no chat chrome in v0.5 (matches prior .sessionStarted arm).
            break

        case .textDelta(let text):
            messages[idx].content += text

        case .thinking:
            // Captured but not rendered — thinking blocks already stream to the Debug pane.
            break

        case .toolUse(let toolID, let name, let input):
            let display = ChatModel.renderJSON(input)
            messages[idx].toolCalls.append(ToolCall(id: toolID, name: name, inputDisplay: display, result: nil, isError: false))

        case .toolResult(let toolID, let content, let isError):
            if let i = messages[idx].toolCalls.firstIndex(where: { $0.id == toolID }) {
                messages[idx].toolCalls[i].result = content
                messages[idx].toolCalls[i].isError = isError
            } else {
                messages[idx].toolCalls.append(ToolCall(id: toolID, name: "(unbound)", inputDisplay: "", result: content, isError: isError))
            }

        case .turnComplete(let usage):
            if let usage {
                lastUsage = TurnTelemetry(
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    costUSD: usage.costUSD,
                    durationMs: usage.durationMs
                )
            }

        case .failed(let message):
            lastError = message
            messages.append(.init(role: .error, content: message))

        case .cancelled:
            messages.append(.init(role: .system, content: "Cancelled."))

        case .backendExited(let code):
            if code != 0 && code != -15 {
                let note = "claude exited with code \(code)"
                lastError = note
                messages.append(.init(role: .error, content: note))
            }
        }
    }
```

- [ ] **Step 4: Update `cancel()` and `clear()` to call the protocol methods**

In `cancel()` (line ~329–331) change `Task { await agent.cancel() }` to `Task { await assistant.cancel() }`. In the clear path (line ~340) change `await agent.resetSession()` to `await assistant.resetSession()`.

- [ ] **Step 5: Update construction call sites**

`SiteWindow.swift:343` already passes `siteID:` — no change needed (the convenience init keeps the same signature). `ChatView.swift:389` preview uses `ChatModel(siteID:siteDirectory:)` — unchanged. Confirm with:

Run: `grep -rn "ChatModel(" Sources/AnglesiteApp/ | grep -v "// "`
Expected: only `siteID:siteDirectory:...` convenience-init call sites; no references to a removed `agent:` label.

- [ ] **Step 6: Build the DevID app target**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`. (Also run `swift test --package-path .` to confirm the Core suites still pass.)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/ChatModel.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/ChatView.swift
git commit -m "refactor(chat): ChatModel depends on ConversationalAssistant, not ClaudeAgent (#153)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Make `ChatModel` target-agnostic (guard shrink)

Remove the file-level `#if !ANGLESITE_MAS` from `ChatModel.swift` so the type compiles on the MAS target; re-gate only the `ClaudeAssistant`-constructing convenience init. The general injecting init (Task 3, Step 1) stays available on both targets. Verified by both app builds.

**Files:**
- Modify: `Sources/AnglesiteApp/ChatModel.swift`

- [ ] **Step 1: Remove the outer guard and update the header comment**

Delete the `#if !ANGLESITE_MAS` on line 4 and its matching `#endif` at end of file. Update the top comment from "The chat panel ships in the Developer ID build only…" to:

```swift
// `ChatModel` is target-agnostic: it depends on the `ConversationalAssistant` protocol, so it
// compiles on both the Developer ID and Mac App Store targets. Only the Claude-backed convenience
// init below is `#if !ANGLESITE_MAS` (the MAS build has no `claude` CLI to shell out to). The MAS
// chat *backend* (FoundationModelAssistant) and *UI* arrive in #155 / #159; until then the MAS
// build compiles `ChatModel` but never constructs it (the SiteWindow chat UI stays DevID-gated).
```

- [ ] **Step 2: Gate only the Claude convenience init**

Wrap the `init(siteID:siteDirectory:annotationFeed:…)` convenience initializer (the one that builds `ClaudeAssistant`) in its own guard, leaving the injecting init ungated:

```swift
    #if !ANGLESITE_MAS
    init(siteID: String, siteDirectory: URL, annotationFeed: AnnotationFeed? = nil, annotationResolver: AnnotationResolver? = nil, undoCommand: UndoCommand? = nil) {
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.assistant = ClaudeAssistant(siteID: siteID, siteDirectory: siteDirectory)
        self.history = ChatHistoryStore(siteDirectory: siteDirectory)
        self.annotationFeed = annotationFeed
        self.annotationResolver = annotationResolver
        self.undoCommand = undoCommand
    }
    #endif
```

- [ ] **Step 3: Build the MAS target and resolve any MAS-only compile errors**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

If it fails, the error names a symbol referenced in `ChatModel`'s body that is itself DevID-gated. For each such symbol, confirm it: (a) lives in `AnglesiteCore`/`AnglesiteBridge` (those packages are never compiled with `ANGLESITE_MAS`, so they're available) — if so the error is elsewhere; or (b) is an app-target type under `#if !ANGLESITE_MAS` — if so, gate the specific member of `ChatModel` that uses it. Do **not** re-add the file-level guard. The expected outcome is that only the convenience init (Step 2) needed gating.

- [ ] **Step 4: Build the DevID target to confirm no regression**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/ChatModel.swift
git commit -m "refactor(chat): make ChatModel compile target-agnostic; gate only Claude init (#153)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Manual verification + close out

- [ ] **Step 1: Manual tool-use smoke (DevID build)**

Launch the DevID app, open a site with chat, send a prompt that triggers a tool call (e.g. `deploy my site` or `/anglesite:check`). Confirm, exactly as before the refactor: streamed assistant text renders incrementally, tool-use rows appear with input + result, and turn telemetry (token counts) updates. This is the behaviour-preservation check that no automated test covers.

- [ ] **Step 2: Full Core test suite**

Run: `swift test --package-path .`
Expected: all suites pass, including the new `ClaudeAssistantTests` and the unchanged `ClaudeAgentTests`.

- [ ] **Step 3: Update issues**

```bash
gh issue close 152 --comment "Done — ClaudeAssistant wraps ClaudeAgent as a ConversationalAssistant with 1:1 event mapping; ClaudeAssistantTests cover the passthrough. See branch feat/content-assistant-refactor."
gh issue close 153 --comment "Done — ChatModel depends on any ConversationalAssistant and consumes AssistantEvent; guard shrunk to only the Claude convenience init so ChatModel compiles on both targets (DevID + AnglesiteMAS builds green). MAS chat backend/UI remain #155/#159."
```

---

## Self-Review

**Spec coverage:**
- §1 agnostic event surface → Task 1 ✅
- §2 refinement protocol + `AssistantError` → Task 1 ✅
- §3 `ClaudeAssistant` + passthrough test → Task 2 ✅
- §4 `ChatModel` seam swap (`converse`, `handle` over `AssistantEvent`, `AssistantContext` from `siteID`/`siteDirectory`) → Task 3 ✅
- §5 MAS gating (shrink guard, dual build) → Task 4 ✅
- Verification (Core test, both `xcodebuild` schemes, manual tool-use) → Tasks 2/3/4/5 ✅
- Out-of-scope (`currentPageRoute`/selector enrichment, MAS backend) → not implemented, noted in code comments ✅

**Type consistency:** `AssistantEvent` cases, `AssistantUsage(inputTokens:outputTokens:costUSD:durationMs:)`, `ConversationalAssistant.converse/cancel/resetSession`, and `ClaudeAssistant.map` are referenced identically across Tasks 1–3. `ChatModel.TurnTelemetry` field names (`inputTokens`, `outputTokens`, `costUSD`, `durationMs`) match the existing struct. `ChatModel` init label `siteID:` matches the existing `SiteWindow`/`ChatView` call sites.

**Placeholder scan:** no TBD/TODO; every code step shows complete code; the one judgement step (Task 4 Step 3) gives an explicit decision procedure rather than "handle errors."
