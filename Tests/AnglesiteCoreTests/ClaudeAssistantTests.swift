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
