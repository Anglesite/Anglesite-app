import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ClaudeAssistant")
struct ClaudeAssistantTests {

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

    @Test("converse maps ClaudeAgent events to AssistantEvents")
    func converseMapsClaudeEventsToAssistantEvents() async throws {
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

        #expect(events == [
            .started(model: "claude-opus-4-8", toolNames: ["Read"]),
            .textDelta("Hi"),
            .toolUse(id: "t1", name: "Read", input: .object(["path": .string("a.md")])),
            .toolResult(id: "t1", content: "ok", isError: false),
            .turnComplete(AssistantUsage(inputTokens: 10, outputTokens: 5, costUSD: 0.01, durationMs: 1200)),
            .backendExited(code: 0),
        ])
    }

    @Test("capabilities report Claude provider")
    func capabilitiesReportClaudeProvider() {
        let caps = ClaudeAssistant(agent: makeAgent(lines: [])).capabilities
        #expect(caps.providerName == "Claude")
        #expect(caps.supportsStreaming)
        #expect(caps.supportsTools)
        #expect(!caps.supportsStructuredOutput)
        #expect(!caps.supportsVision)
    }

    @Test("generate yields only text chunks, dropping tool-use and telemetry events")
    func generateYieldsTextChunksOnly() async throws {
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s1","model":"m","tools":[]}"#,
            #"{"type":"assistant","message":{"id":"a1","content":[{"type":"text","text":"Hello "}]}}"#,
            #"{"type":"assistant","message":{"id":"a2","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":false}]}}"#,
            #"{"type":"assistant","message":{"id":"a3","content":[{"type":"text","text":"world"}]}}"#,
            #"{"type":"result","subtype":"success","usage":{"input_tokens":1,"output_tokens":1}}"#,
        ]
        let assistant = ClaudeAssistant(agent: makeAgent(lines: lines, exit: 0))
        let context = AssistantContext(siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/site"))

        var chunks: [String] = []
        for try await chunk in try await assistant.generate(prompt: "hi", context: context) {
            chunks.append(chunk)
        }
        // Only the two text blocks survive — started/tool-use/tool-result/turn-complete/exit are dropped.
        #expect(chunks == ["Hello ", "world"])
    }

    @Test("generate throws streamFailed when the stream reports an in-band error")
    func generateThrowsStreamFailedOnError() async throws {
        let lines = [
            #"{"type":"assistant","message":{"id":"a1","content":[{"type":"text","text":"partial"}]}}"#,
            #"{"type":"error","message":"boom"}"#,
        ]
        let assistant = ClaudeAssistant(agent: makeAgent(lines: lines, exit: 1))
        let context = AssistantContext(siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/site"))

        await #expect(throws: AssistantError.streamFailed("boom")) {
            for try await _ in try await assistant.generate(prompt: "hi", context: context) {}
        }
    }
}
