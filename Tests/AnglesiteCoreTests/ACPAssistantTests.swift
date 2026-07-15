import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ACPAssistantTests {
    private actor FakeACPAgentTransport: ACPTransport {
        private var continuation: AsyncStream<JSONValue>.Continuation?
        private let stream: AsyncStream<JSONValue>

        init() {
            var cont: AsyncStream<JSONValue>.Continuation!
            stream = AsyncStream { cont = $0 }
            continuation = cont
        }

        func open() async throws {}
        nonisolated func inbound() -> AsyncStream<JSONValue> { stream }
        func close() async { continuation?.finish() }

        func send(_ message: JSONValue) async throws {
            guard case .object(let obj) = message, case .string(let method)? = obj["method"],
                  case .int(let id)? = obj["id"] else { return }
            switch method {
            case "initialize":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object([:])]))
            case "session/new":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object(["sessionId": .string("sess-1")])]))
            case "session/prompt":
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object([
                    "sessionId": .string("sess-1"),
                    "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Hi there")])]),
                ])]))
                continuation?.yield(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": .object(["stopReason": .string("end_turn")])]))
            default:
                break
            }
        }
    }

    private func makeAssistant() -> ACPAssistant {
        let connection = ACPAgentConnection(id: UUID(), name: "Test Agent", transport: .remote(url: URL(string: "https://example.com")!))
        return ACPAssistant(
            connection: connection,
            siteID: "site-1",
            sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            transportFactory: { FakeACPAgentTransport() }
        )
    }

    @Test func generateYieldsTheAgentsTextReply() async throws {
        let assistant = makeAssistant()
        let context = AssistantContext(siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site-1"))
        let stream = try await assistant.generate(prompt: "hello", context: context)
        var collected = ""
        for try await chunk in stream { collected += chunk }
        #expect(collected == "Hi there")
    }

    @Test func capabilitiesReportsTheConnectionName() {
        let connection = ACPAgentConnection(id: UUID(), name: "My Agent", transport: .remote(url: URL(string: "https://example.com")!))
        let assistant = ACPAssistant(
            connection: connection, siteID: "site-1", sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            transportFactory: { FakeACPAgentTransport() })
        #expect(assistant.capabilities.providerName == "My Agent")
    }
}
