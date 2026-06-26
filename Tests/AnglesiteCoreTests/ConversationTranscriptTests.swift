import Testing
import Foundation
@testable import AnglesiteCore

// `ConversationTranscript` is the provider-agnostic event-accumulation reducer extracted from
// `ChatModel` (App target) so it can be unit-tested without the App's SwiftUI/persistence shell
// (#161 items 5 & 7). It depends only on `AssistantEvent`/`JSONValue`/`FoundationModelTier`, none
// of which are behind the `compiler(>=6.4)` FoundationModels gate, so the suite runs on CI.

@Suite("ConversationTranscript: turn lifecycle")
struct ConversationTranscriptLifecycleTests {

    @Test("beginTurn appends the user prompt and an empty assistant message")
    func beginTurnAppendsUserAndEmptyAssistant() {
        var t = ConversationTranscript()
        t.beginTurn(userPrompt: "hi")
        #expect(t.messages.count == 2)
        #expect(t.messages[0].role == .user)
        #expect(t.messages[0].content == "hi")
        #expect(t.messages[1].role == .assistant)
        #expect(t.messages[1].content == "")
    }

    @Test("beginTurn clears a stale lastError")
    func beginTurnClearsLastError() {
        var t = ConversationTranscript()
        t.beginTurn(userPrompt: "first")
        t.apply(.failed(message: "boom"))
        #expect(t.lastError == "boom")
        t.beginTurn(userPrompt: "second")
        #expect(t.lastError == nil)
    }

    @Test("events before beginTurn are ignored (no in-flight message)")
    func eventsBeforeBeginTurnAreIgnored() {
        var t = ConversationTranscript()
        t.apply(.textDelta("x"))
        t.apply(.toolResult(id: "a", content: "b", isError: false))
        #expect(t.messages.isEmpty)
    }

    @Test("beginTurn returns the user message it appended")
    func beginTurnReturnsUserMessage() {
        var t = ConversationTranscript()
        let user = t.beginTurn(userPrompt: "hi there")
        #expect(user.role == .user)
        #expect(user.content == "hi there")
        // The returned message is the same one stored in the transcript.
        #expect(t.messages.contains { $0.id == user.id })
    }

    @Test("beginTurn while a turn is in flight starts a fresh turn and re-points the in-flight row")
    func beginTurnWhileInFlightStartsFreshTurn() {
        var t = ConversationTranscript()
        t.beginTurn(userPrompt: "first")
        t.apply(.textDelta("one"))
        t.beginTurn(userPrompt: "second")
        t.apply(.textDelta("two"))
        // The previous assistant row is left finalized; deltas now extend the new assistant row.
        #expect(t.messages.map(\.content) == ["first", "one", "second", "two"])
    }

    @Test("endTurn returns the in-flight assistant message and clears the in-flight marker")
    func endTurnReturnsAssistantAndClearsInFlight() {
        var t = ConversationTranscript()
        t.beginTurn(userPrompt: "hi")
        t.apply(.textDelta("done"))
        let final = t.endTurn()
        #expect(final?.role == .assistant)
        #expect(final?.content == "done")
        // After endTurn, further deltas have no in-flight target and are dropped.
        t.apply(.textDelta(" more"))
        #expect(t.messages[1].content == "done")
    }

    @Test("reset clears messages and the in-flight marker")
    func resetClearsMessagesAndInFlight() {
        var t = ConversationTranscript()
        t.beginTurn(userPrompt: "hi")
        t.apply(.textDelta("partial"))
        t.reset()
        #expect(t.messages.isEmpty)
        // A subsequent delta is ignored until a new turn begins.
        t.apply(.textDelta("ignored"))
        #expect(t.messages.isEmpty)
        // A fresh turn works cleanly.
        t.beginTurn(userPrompt: "again")
        #expect(t.messages.count == 2)
    }
}

@Suite("ConversationTranscript: event accumulation")
struct ConversationTranscriptEventTests {

    private func started() -> ConversationTranscript {
        var t = ConversationTranscript()
        t.beginTurn(userPrompt: "go")
        return t
    }

    @Test("textDeltas accumulate into the in-flight assistant message")
    func textDeltasAccumulate() {
        var t = started()
        t.apply(.textDelta("Hel"))
        t.apply(.textDelta("lo"))
        #expect(t.messages[1].content == "Hello")
    }

    @Test(".started and .thinking do not mutate the transcript")
    func startedAndThinkingAreInert() {
        var t = started()
        let before = t.messages
        t.apply(.started(model: "on-device", toolNames: ["apply_edit"]))
        t.apply(.thinking("hmm"))
        #expect(t.messages.map(\.content) == before.map(\.content))
        #expect(t.messages[1].toolCalls.isEmpty)
    }

    @Test("toolUse then toolResult pair by id on the assistant message")
    func toolUseThenResultPairsByID() {
        var t = started()
        t.apply(.toolUse(id: "t1", name: "apply_edit", input: .object(["op": .string("replace")])))
        t.apply(.toolResult(id: "t1", content: "applied", isError: false))
        #expect(t.messages[1].toolCalls.count == 1)
        let call = t.messages[1].toolCalls[0]
        #expect(call.id == "t1")
        #expect(call.name == "apply_edit")
        #expect(call.result == "applied")
        #expect(call.isError == false)
        #expect(call.inputDisplay.contains("replace"))
    }

    @Test("a toolResult with no matching toolUse surfaces as an unbound call")
    func toolResultWithoutMatchingUseIsUnbound() {
        var t = started()
        t.apply(.toolResult(id: "orphan", content: "result-only", isError: true))
        #expect(t.messages[1].toolCalls.count == 1)
        let call = t.messages[1].toolCalls[0]
        #expect(call.name == "(unbound)")
        #expect(call.result == "result-only")
        #expect(call.isError == true)
    }

    @Test("turnComplete with usage captures lastUsage")
    func turnCompleteCapturesUsage() {
        var t = started()
        t.apply(.turnComplete(AssistantUsage(inputTokens: 12, outputTokens: 7, costUSD: 0.01, durationMs: 200)))
        #expect(t.lastUsage?.inputTokens == 12)
        #expect(t.lastUsage?.outputTokens == 7)
        #expect(t.lastUsage?.costUSD == 0.01)
    }

    @Test("turnComplete with nil usage leaves lastUsage unchanged")
    func turnCompleteNilUsageIsNoOp() {
        var t = started()
        t.apply(.turnComplete(nil))
        #expect(t.lastUsage == nil)
    }

    @Test("failed sets lastError and appends an error row")
    func failedSetsErrorAndAppendsRow() {
        var t = started()
        t.apply(.failed(message: "model exploded"))
        #expect(t.lastError == "model exploded")
        #expect(t.messages.last?.role == .error)
        #expect(t.messages.last?.content == "model exploded")
    }

    @Test("cancelled appends a system row")
    func cancelledAppendsSystemRow() {
        var t = started()
        t.apply(.cancelled)
        #expect(t.messages.last?.role == .system)
        #expect(t.messages.last?.content == "Cancelled.")
    }

    @Test("backendExited with a nonzero code appends an error naming the provider")
    func backendExitedNonzeroAppendsError() {
        var t = ConversationTranscript(providerName: "On-Device")
        t.beginTurn(userPrompt: "go")
        t.apply(.backendExited(code: 1))
        #expect(t.lastError?.contains("On-Device") == true)
        #expect(t.lastError?.contains("1") == true)
        #expect(t.messages.last?.role == .error)
    }

    @Test("backendExited with a clean (0) or SIGTERM (-15) code is ignored")
    func backendExitedCleanCodesIgnored() {
        var t = started()
        t.apply(.backendExited(code: 0))
        t.apply(.backendExited(code: -15))
        #expect(t.lastError == nil)
        #expect(!t.messages.contains { $0.role == .error })
    }

    @Test("a full tool-using turn accumulates text + a paired tool call + usage")
    func fullToolUsingTurnSmoke() {
        var t = ConversationTranscript(providerName: "On-Device")
        t.beginTurn(userPrompt: "edit my homepage")
        t.apply(.started(model: "on-device", toolNames: ["apply_edit", "search_content"]))
        t.apply(.textDelta("Sure, "))
        t.apply(.toolUse(id: "u1", name: "apply_edit", input: .object(["selector": .string("h1")])))
        t.apply(.toolResult(id: "u1", content: "edited index.md", isError: false))
        t.apply(.textDelta("done."))
        t.apply(.turnComplete(AssistantUsage(inputTokens: 30, outputTokens: 9, costUSD: nil, durationMs: nil)))
        let final = t.endTurn()

        #expect(t.messages.count == 2)
        #expect(t.messages[0].role == .user)
        #expect(final?.content == "Sure, done.")
        #expect(final?.toolCalls.count == 1)
        #expect(final?.toolCalls.first?.result == "edited index.md")
        #expect(t.lastUsage?.inputTokens == 30)
        #expect(t.lastError == nil)
    }
}

@Suite("ConversationTranscript: out-of-band rows")
struct ConversationTranscriptAppendTests {

    @Test("append preserves order and does not redirect in-flight text deltas")
    func appendPreservesOrderDuringTurn() {
        var t = ConversationTranscript()
        t.beginTurn(userPrompt: "hi")
        t.apply(.textDelta("partial"))
        let edit = ChatMessage(role: .edit, content: "Edited index.md",
                               editMetadata: ChatEditMetadata(file: "index.md", commit: "abc123", undone: false))
        t.append(edit)
        // Order: [user, assistant, edit]
        #expect(t.messages.map(\.role) == [.user, .assistant, .edit])
        // The in-flight assistant message (not the appended edit row) keeps receiving deltas.
        t.apply(.textDelta(" more"))
        #expect(t.messages[1].content == "partial more")
        #expect(t.messages[2].content == "Edited index.md")
    }

    @Test("update mutates the identified message in place")
    func updateMutatesByID() {
        var t = ConversationTranscript()
        let edit = ChatMessage(role: .edit, content: "Edited index.md",
                               editMetadata: ChatEditMetadata(file: "index.md", commit: "abc123", undone: false))
        t.append(edit)
        t.update(id: edit.id) { $0.editMetadata?.undone = true }
        #expect(t.messages[0].editMetadata?.undone == true)
    }

    @Test("remove returns and drops the identified message; missing id is a no-op")
    func removeReturnsAndDrops() {
        var t = ConversationTranscript()
        let a = ChatMessage(role: .annotation, content: "note A")
        let b = ChatMessage(role: .annotation, content: "note B")
        t.append(a)
        t.append(b)
        let removed = t.remove(id: a.id)
        #expect(removed?.content == "note A")
        #expect(t.messages.map(\.content) == ["note B"])
        #expect(t.remove(id: a.id) == nil)
        #expect(t.messages.count == 1)
    }

    @Test("insertByTimestamp restores a row at its chronological position")
    func insertByTimestampRestoresOrder() {
        let base = Date(timeIntervalSince1970: 1_000)
        var t = ConversationTranscript()
        let first = ChatMessage(role: .annotation, content: "first", timestamp: base)
        let third = ChatMessage(role: .annotation, content: "third", timestamp: base.addingTimeInterval(20))
        let second = ChatMessage(role: .annotation, content: "second", timestamp: base.addingTimeInterval(10))
        t.append(first)
        t.append(third)
        // Re-inserting `second` must land it between `first` and `third` by timestamp.
        t.insertByTimestamp(second)
        #expect(t.messages.map(\.content) == ["first", "second", "third"])
    }

    @Test("insertByTimestamp appends when newest")
    func insertByTimestampAppendsWhenNewest() {
        let base = Date(timeIntervalSince1970: 1_000)
        var t = ConversationTranscript()
        t.append(ChatMessage(role: .annotation, content: "old", timestamp: base))
        t.insertByTimestamp(ChatMessage(role: .annotation, content: "new", timestamp: base.addingTimeInterval(50)))
        #expect(t.messages.map(\.content) == ["old", "new"])
    }

    // Regression: `resolveAnnotation` can `remove`/`insertByTimestamp` rows *during* a streaming
    // turn (it suspends on the MainActor at its `await`, letting the stream loop resume). If the
    // in-flight assistant row were tracked by array index, these mutations would shift it and send
    // deltas to the wrong row. The in-flight row is tracked by id, so the turn is unaffected.

    @Test("removing a row before the in-flight assistant keeps deltas on the assistant")
    func removeBeforeInFlightKeepsDeltasOnAssistant() {
        var t = ConversationTranscript()
        let note = ChatMessage(role: .annotation, content: "note", timestamp: Date(timeIntervalSince1970: 1))
        t.append(note)                  // [note]
        t.beginTurn(userPrompt: "go")   // [note, user, assistant]
        t.apply(.textDelta("A"))
        t.remove(id: note.id)           // [user, assistant] — assistant shifts down by one
        t.apply(.textDelta("B"))
        let assistant = t.messages.first { $0.role == .assistant }
        #expect(assistant?.content == "AB")
        #expect(t.messages.first?.role == .user)
    }

    @Test("inserting a row before the in-flight assistant keeps deltas on the assistant")
    func insertBeforeInFlightKeepsDeltasOnAssistant() {
        var t = ConversationTranscript()
        t.beginTurn(userPrompt: "go")   // [user, assistant], both stamped "now"
        t.apply(.textDelta("A"))
        // A restored annotation with an older timestamp lands at the front, shifting the assistant.
        let note = ChatMessage(role: .annotation, content: "note", timestamp: Date(timeIntervalSince1970: 1))
        t.insertByTimestamp(note)       // [note, user, assistant]
        t.apply(.textDelta("B"))
        let assistant = t.messages.first { $0.role == .assistant }
        #expect(assistant?.content == "AB")
        // The user row must be untouched (a stale index would have appended "B" here).
        #expect(t.messages.first { $0.role == .user }?.content == "go")
    }
}
