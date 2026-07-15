// Tests/AnglesiteCoreTests/ACPClientTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ACPClientTests {
    /// In-process fake `ACPTransport`, mirroring `MCPClientTests`'s `FakeMCPServerTransport`:
    /// responses/notifications are yielded synchronously from `send(_:)`, no subprocess, no
    /// wall-clock dependency.
    private actor FakeACPAgentTransport: ACPTransport {
        private var continuation: AsyncStream<JSONValue>.Continuation?
        private let stream: AsyncStream<JSONValue>
        /// Extra `session/update` notifications to emit right after the `session/prompt` response
        /// this test wants to exercise (set per test before calling `sendPrompt`).
        private var updatesToEmitBeforePromptResult: [JSONValue] = []
        private(set) var sentMethods: [String] = []

        init() {
            var cont: AsyncStream<JSONValue>.Continuation!
            stream = AsyncStream { cont = $0 }
            continuation = cont
        }

        func setUpdatesToEmit(_ updates: [JSONValue]) {
            updatesToEmitBeforePromptResult = updates
        }

        func open() async throws {}
        nonisolated func inbound() -> AsyncStream<JSONValue> { stream }
        func close() async { continuation?.finish() }

        func send(_ message: JSONValue) async throws {
            guard case .object(let obj) = message, case .string(let method)? = obj["method"] else { return }
            sentMethods.append(method)
            guard case .int(let id)? = obj["id"] else { return }  // notifications get no response
            switch method {
            case "initialize":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object([:])]))
            case "session/new":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object(["sessionId": .string("sess-1")])]))
            case "session/prompt":
                for update in updatesToEmitBeforePromptResult { continuation?.yield(update) }
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object(["stopReason": .string("end_turn")])]))
            default:
                break
            }
        }
    }

    @Test func initializeSucceedsAgainstAConformingAgent() async throws {
        let client = ACPClient(transport: FakeACPAgentTransport())
        try await client.initialize()
    }

    @Test func newSessionReturnsTheAgentAssignedSessionID() async throws {
        let client = ACPClient(transport: FakeACPAgentTransport())
        try await client.initialize()
        let sessionID = try await client.newSession(cwd: "/workspace/site")
        #expect(sessionID == "sess-1")
    }

    @Test func sendPromptStreamsTextDeltasThenTurnComplete() async throws {
        let transport = FakeACPAgentTransport()
        await transport.setUpdatesToEmit([
            .object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object([
                "sessionId": .string("sess-1"),
                "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Hello")])]),
            ])]),
        ])
        let client = ACPClient(transport: transport)
        try await client.initialize()
        let sessionID = try await client.newSession(cwd: "/workspace/site")
        let events = try await client.sendPrompt(sessionID: sessionID, text: "hi")
        var collected: [AssistantEvent] = []
        for await event in events { collected.append(event) }
        #expect(collected.contains(.textDelta("Hello")))
        #expect(collected.contains(.turnComplete(nil)))
    }
}
