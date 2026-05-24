import XCTest
@testable import AnglesiteCore

final class ClaudeAgentTests: XCTestCase {

    // MARK: Parser — system/init

    func testParsesSystemInitWithModelAndTools() {
        let line = #"{"type":"system","subtype":"init","session_id":"sess-123","model":"claude-opus-4-7","tools":["Read","Edit",{"name":"Bash"}]}"#
        let events = ClaudeAgent.StreamJSONParser.parse(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .sessionStarted(let sid, let model, let names) = events[0] else {
            return XCTFail("expected .sessionStarted, got \(events)")
        }
        XCTAssertEqual(sid, "sess-123")
        XCTAssertEqual(model, "claude-opus-4-7")
        XCTAssertEqual(Set(names), Set(["Read", "Edit", "Bash"]))
    }

    // MARK: Parser — assistant messages

    func testParsesAssistantTextBlock() {
        let line = #"{"type":"assistant","message":{"id":"msg_01","content":[{"type":"text","text":"Hello there."}]}}"#
        let events = ClaudeAgent.StreamJSONParser.parse(line: line)
        XCTAssertEqual(events, [.assistantText(messageID: "msg_01", text: "Hello there.")])
    }

    func testParsesAssistantToolUseBlock() {
        let line = #"{"type":"assistant","message":{"id":"msg_02","content":[{"type":"tool_use","id":"toolu_abc","name":"Read","input":{"file_path":"/x/y.txt"}}]}}"#
        let events = ClaudeAgent.StreamJSONParser.parse(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .toolUse(let id, let name, let input) = events[0] else {
            return XCTFail("expected .toolUse, got \(events)")
        }
        XCTAssertEqual(id, "toolu_abc")
        XCTAssertEqual(name, "Read")
        XCTAssertEqual(input, .object(["file_path": .string("/x/y.txt")]))
    }

    func testParsesAssistantMessageWithMultipleContentBlocks() {
        // One assistant message can carry text + tool_use + thinking together.
        let line = #"""
        {"type":"assistant","message":{"id":"msg_03","content":[
            {"type":"text","text":"Reading the file…"},
            {"type":"tool_use","id":"toolu_xyz","name":"Read","input":{"file_path":"a.md"}},
            {"type":"thinking","thinking":"I should also check b.md."}
        ]}}
        """#.replacingOccurrences(of: "\n", with: "")
        let events = ClaudeAgent.StreamJSONParser.parse(line: line)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .assistantText(messageID: "msg_03", text: "Reading the file…"))
        if case .toolUse(let id, let name, _) = events[1] {
            XCTAssertEqual(id, "toolu_xyz")
            XCTAssertEqual(name, "Read")
        } else { XCTFail("expected .toolUse at index 1") }
        XCTAssertEqual(events[2], .assistantThinking(text: "I should also check b.md."))
    }

    func testIgnoresEmptyTextBlocks() {
        let line = #"{"type":"assistant","message":{"id":"x","content":[{"type":"text","text":""}]}}"#
        XCTAssertEqual(ClaudeAgent.StreamJSONParser.parse(line: line), [])
    }

    // MARK: Parser — user/tool_result messages

    func testParsesToolResultWithStringContent() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"file body","is_error":false}]}}"#
        let events = ClaudeAgent.StreamJSONParser.parse(line: line)
        XCTAssertEqual(events, [.toolResult(toolUseID: "toolu_abc", content: "file body", isError: false)])
    }

    func testParsesToolResultWithStructuredContent() {
        // Newer claude versions wrap tool-result content in typed parts.
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"line 1"},{"type":"text","text":"line 2"}]}]}}"#
        let events = ClaudeAgent.StreamJSONParser.parse(line: line)
        XCTAssertEqual(events, [.toolResult(toolUseID: "t1", content: "line 1\nline 2", isError: false)])
    }

    func testParsesToolResultErrorFlag() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"permission denied","is_error":true}]}}"#
        let events = ClaudeAgent.StreamJSONParser.parse(line: line)
        XCTAssertEqual(events, [.toolResult(toolUseID: "t2", content: "permission denied", isError: true)])
    }

    // MARK: Parser — result/error

    func testParsesResultSummaryWithUsageAndCost() {
        let line = #"{"type":"result","subtype":"success","total_cost_usd":0.0123,"duration_ms":4321,"stop_reason":"end_turn","usage":{"input_tokens":120,"output_tokens":340,"cache_read_input_tokens":5000,"cache_creation_input_tokens":200}}"#
        let events = ClaudeAgent.StreamJSONParser.parse(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .turnComplete(let usage, let cost, let durationMs, let stopReason) = events[0] else {
            return XCTFail("expected .turnComplete, got \(events)")
        }
        XCTAssertEqual(usage?.inputTokens, 120)
        XCTAssertEqual(usage?.outputTokens, 340)
        XCTAssertEqual(usage?.cacheReadInputTokens, 5000)
        XCTAssertEqual(usage?.cacheCreationInputTokens, 200)
        XCTAssertEqual(cost ?? -1, 0.0123, accuracy: 0.0001)
        XCTAssertEqual(durationMs, 4321)
        XCTAssertEqual(stopReason, "end_turn")
    }

    func testParsesErrorLine() {
        let line = #"{"type":"error","message":"network unreachable"}"#
        XCTAssertEqual(ClaudeAgent.StreamJSONParser.parse(line: line), [.streamError(message: "network unreachable")])
    }

    func testIgnoresUnknownTopLevelTypes() {
        XCTAssertEqual(ClaudeAgent.StreamJSONParser.parse(line: #"{"type":"unknown_future_thing","payload":42}"#), [])
    }

    func testIgnoresMalformedJSON() {
        XCTAssertEqual(ClaudeAgent.StreamJSONParser.parse(line: "not json at all"), [])
        XCTAssertEqual(ClaudeAgent.StreamJSONParser.parse(line: "{type:missing_quotes}"), [])
    }

    // MARK: Argument construction

    func testBuildArgumentsIncludesPluginAndStreamFlagsForFirstMessage() {
        let args = ClaudeAgent.LaunchArgs(
            prompt: "hi there",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"),
            pluginDirectory: URL(fileURLWithPath: "/Resources/plugin"),
            resumeSession: false
        )
        let argv = ClaudeAgent.buildArguments(for: args)
        XCTAssertTrue(argv.contains("--print"))
        XCTAssertTrue(argv.contains("--output-format"))
        XCTAssertTrue(argv.contains("stream-json"))
        XCTAssertEqual(argv.firstIndex(of: "--plugin-dir").map { argv[$0 + 1] }, "/Resources/plugin")
        XCTAssertFalse(argv.contains("--continue"))
        XCTAssertEqual(argv.last, "hi there", "prompt must be the trailing positional arg")
    }

    func testBuildArgumentsAddsContinueOnResume() {
        let args = ClaudeAgent.LaunchArgs(
            prompt: "follow-up",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"),
            pluginDirectory: nil,
            resumeSession: true
        )
        let argv = ClaudeAgent.buildArguments(for: args)
        XCTAssertTrue(argv.contains("--continue"))
        XCTAssertFalse(argv.contains("--plugin-dir"), "must not emit --plugin-dir when plugin path is nil")
    }

    func testBuildArgumentsPrependsEnvSentinelWhenExecutableIsEnv() {
        // The supervisor-backed launcher falls back to /usr/bin/env when `claude` isn't on
        // PATH at app launch; in that case the first argv element must be the binary name.
        let args = ClaudeAgent.LaunchArgs(
            prompt: "hello",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"),
            pluginDirectory: nil,
            resumeSession: false
        )
        let argv = ClaudeAgent.buildArguments(for: args, executableIsEnv: true)
        XCTAssertEqual(argv.first, "claude")
    }

    // MARK: Send/cancel lifecycle with fixture launcher

    func testSendYieldsParsedEventsThenProcessExited() async throws {
        let fixtureLines = [
            #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus-4-7","tools":["Read"]}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hi."}]}}"#,
            #"{"type":"result","subtype":"success","total_cost_usd":0.001,"duration_ms":100,"usage":{"input_tokens":10,"output_tokens":5}}"#
        ]
        let launcher: ClaudeAgent.Launcher = { _ in
            let stream = AsyncStream<String> { continuation in
                for line in fixtureLines { continuation.yield(line) }
                continuation.finish()
            }
            return ClaudeAgent.LaunchResult(
                lines: stream,
                cancel: { },
                waitForExit: { 0 }
            )
        }
        let agent = ClaudeAgent(
            siteDirectory: URL(fileURLWithPath: "/tmp/site"),
            pluginDirectory: nil,
            launcher: launcher
        )
        var events: [ClaudeAgent.Event] = []
        for await event in try await agent.send(prompt: "hi") {
            events.append(event)
        }
        XCTAssertEqual(events.count, 4, "init + assistant + result + processExited")
        if case .sessionStarted(let sid, let model, _) = events[0] {
            XCTAssertEqual(sid, "s1")
            XCTAssertEqual(model, "claude-opus-4-7")
        } else { XCTFail("expected .sessionStarted, got \(events[0])") }
        XCTAssertEqual(events[1], .assistantText(messageID: "m1", text: "Hi."))
        if case .turnComplete = events[2] {} else { XCTFail("expected .turnComplete at 2") }
        XCTAssertEqual(events[3], .processExited(code: 0))
    }

    func testResumeSessionFlagPropagatesAcrossSends() async throws {
        let captured = ArgvSink()
        let launcher: ClaudeAgent.Launcher = { args in
            await captured.record(resumeSession: args.resumeSession)
            return ClaudeAgent.LaunchResult(
                lines: AsyncStream { $0.finish() },
                cancel: { },
                waitForExit: { 0 }
            )
        }
        let agent = ClaudeAgent(siteDirectory: URL(fileURLWithPath: "/tmp"), pluginDirectory: nil, launcher: launcher)
        for await _ in try await agent.send(prompt: "first") {}
        for await _ in try await agent.send(prompt: "second") {}
        let recorded = await captured.values
        XCTAssertEqual(recorded, [false, true], "first send must not resume; subsequent sends must")
    }

    func testResetSessionForcesFreshConversation() async throws {
        let captured = ArgvSink()
        let launcher: ClaudeAgent.Launcher = { args in
            await captured.record(resumeSession: args.resumeSession)
            return ClaudeAgent.LaunchResult(
                lines: AsyncStream { $0.finish() },
                cancel: { },
                waitForExit: { 0 }
            )
        }
        let agent = ClaudeAgent(siteDirectory: URL(fileURLWithPath: "/tmp"), pluginDirectory: nil, launcher: launcher)
        for await _ in try await agent.send(prompt: "first") {}
        for await _ in try await agent.send(prompt: "second") {}
        await agent.resetSession()
        for await _ in try await agent.send(prompt: "third (fresh)") {}
        let recorded = await captured.values
        XCTAssertEqual(recorded, [false, true, false])
    }

    func testCancelInvokesLauncherCancelHook() async throws {
        let cancelSignal = CancelSignal()
        let launcher: ClaudeAgent.Launcher = { _ in
            let stream = AsyncStream<String> { continuation in
                // Stays open until cancel is called.
                Task {
                    await cancelSignal.wait()
                    continuation.finish()
                }
            }
            return ClaudeAgent.LaunchResult(
                lines: stream,
                cancel: { await cancelSignal.signal() },
                waitForExit: { -15 }
            )
        }
        let agent = ClaudeAgent(siteDirectory: URL(fileURLWithPath: "/tmp"), pluginDirectory: nil, launcher: launcher)
        let stream = try await agent.send(prompt: "long-running")

        // After a moment, cancel.
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await agent.cancel()
        }

        var events: [ClaudeAgent.Event] = []
        for await event in stream { events.append(event) }
        XCTAssertEqual(events.last, .processExited(code: -15))
        let signaled = await cancelSignal.wasSignaled
        XCTAssertTrue(signaled, "cancel hook must have fired")
    }

    func testLauncherThrowSurfacesAsError() async {
        struct LauncherError: Error {}
        let agent = ClaudeAgent(siteDirectory: URL(fileURLWithPath: "/tmp"), pluginDirectory: nil, launcher: { _ in throw LauncherError() })
        do {
            _ = try await agent.send(prompt: "x")
            XCTFail("expected throw")
        } catch is LauncherError {
            // pass
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

// MARK: - Test helpers

private actor ArgvSink {
    private(set) var values: [Bool] = []
    func record(resumeSession: Bool) { values.append(resumeSession) }
}

private actor CancelSignal {
    private(set) var wasSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func signal() {
        wasSignaled = true
        let pending = continuations
        continuations.removeAll()
        for c in pending { c.resume() }
    }

    func wait() async {
        if wasSignaled { return }
        await withCheckedContinuation { continuations.append($0) }
    }
}
