import Testing
import Foundation
@testable import AnglesiteCore

/// A dedicated `URLProtocol` stub for these tests — modeled on `StubURLProtocol`
/// (`HTTPTransportTests.swift`) but a separate type/instance so this suite's per-test queue
/// mutations can never race with that suite's, even though both can run concurrently.
final class ACPStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let status: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var lastAuthHeaders: [String?] = []

    static func reset() { queue = []; lastAuthHeaders = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastAuthHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
        let r = Self.queue.isEmpty ? Response(status: 500, headers: [:], body: Data()) : Self.queue.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct ACPHTTPTransportTests {
    private func makeTransport(bearerToken: SessionToken? = nil) -> ACPHTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ACPStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return ACPHTTPTransport(endpoint: URL(string: "https://agent.example.com/acp")!, bearerToken: bearerToken, urlSession: session)
    }

    @Test("send posts JSON-RPC and decodes the response") func sendPostsJSONRPCAndDecodesTheResponse() async throws {
        ACPStubURLProtocol.reset()
        ACPStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.data(using: .utf8)!
        ))
        let transport = makeTransport(bearerToken: SessionToken(value: "test-token"))
        try await transport.open()
        var iterator = transport.inbound().makeAsyncIterator()
        try await transport.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize")]))
        let received = await iterator.next()
        #expect(received == .object(["jsonrpc": .string("2.0"), "id": .int(1), "result": .object(["ok": .bool(true)])]))
        #expect(ACPStubURLProtocol.lastAuthHeaders == ["Bearer test-token"])
        await transport.close()
    }

    @Test("non-2xx status throws") func nonTwoHundredStatusThrows() async throws {
        ACPStubURLProtocol.reset()
        ACPStubURLProtocol.queue.append(.init(status: 500, headers: [:], body: Data()))
        let transport = makeTransport()
        try await transport.open()
        await #expect(throws: (any Error).self) {
            try await transport.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize")]))
        }
        await transport.close()
    }

    @Test("SSE response yields every event, not just the first") func sseYieldsEveryEvent() async throws {
        ACPStubURLProtocol.reset()
        // One `session/prompt` POST's SSE stream carries a `session/update` push notification
        // (no "id") followed by the final JSON-RPC response (has "id") to that same request.
        // Both must reach `inbound()` — dropping any but the first is the bug this fixes.
        let update = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionUpdate":"agent_message_chunk"}}"#
        let finalResponse = #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#
        let body = "data: \(update)\n\ndata: \(finalResponse)\n\n".data(using: .utf8)!
        ACPStubURLProtocol.queue.append(.init(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: body
        ))
        let transport = makeTransport()
        try await transport.open()
        var iterator = transport.inbound().makeAsyncIterator()
        try await transport.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("session/prompt")]))

        let first = await iterator.next()
        #expect(first == .object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object(["sessionUpdate": .string("agent_message_chunk")])
        ]))

        let second = await iterator.next()
        #expect(second == .object([
            "jsonrpc": .string("2.0"),
            "id": .int(1),
            "result": .object(["stopReason": .string("end_turn")])
        ]))

        await transport.close()
    }
}
