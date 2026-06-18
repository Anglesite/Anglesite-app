// Tests/AnglesiteCoreTests/MCPClientCancellationTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Transport that answers `initialize` (to let the handshake complete) and records every send,
/// but never replies to any other request — so a `callTool` hangs until cancelled.
private actor HangingTransport: MCPTransport {
    private(set) var sentMethods: [String] = []
    private var continuation: AsyncStream<JSONValue>.Continuation?
    private let stream: AsyncStream<JSONValue>
    init() {
        var cont: AsyncStream<JSONValue>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }
    func sentMethodsSnapshot() -> [String] { sentMethods }
    func open() async throws {}
    nonisolated func inbound() -> AsyncStream<JSONValue> { stream }
    func close() async { continuation?.finish() }
    func send(_ message: JSONValue) async throws {
        guard case .object(let obj) = message,
              case .string(let method)? = obj["method"] else { return }
        sentMethods.append(method)
        if method == "initialize", case .int(let id)? = obj["id"] {
            // Minimal valid initialize response so the handshake completes.
            continuation?.yield(.object([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "result": .object(["protocolVersion": .string("2024-11-05"), "capabilities": .object([:])]),
            ]))
        }
        // tools/call: deliberately no response.
    }
}

@Suite(.serialized)
struct MCPClientCancellationTests {
    private func makeInitializedClient() async throws -> (MCPClient, HangingTransport) {
        let transport = HangingTransport()
        let client = MCPClient(supervisor: .shared)
        try await client.startWithTransport(transport, initializeTimeout: 5, clientName: "test", clientVersion: "0")
        return (client, transport)
    }

    @Test("a call whose task is cancelled mid-flight throws CancellationError, not timeout")
    func inFlightCancel() async throws {
        let (client, _) = try await makeInitializedClient()
        let task = Task { try await client.callTool(name: "echo", arguments: .object([:])) }
        // Give the call time to register its pending continuation, then cancel.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("a call whose task is cancelled before it runs never sends tools/call")
    func preCancelledSendsNothing() async throws {
        let (client, transport) = try await makeInitializedClient()
        // Gate the task so we can cancel it *before* callTool runs — deterministic, no sleep race.
        let gate = Gate()
        let task = Task {
            await gate.wait()   // suspends here; resumes only after release()
            return try await client.callTool(name: "echo", arguments: .object([:]))
        }
        task.cancel()           // task is parked at gate.wait(), so this lands before the call
        await gate.release()     // now callTool runs and its pre-call checkCancellation() fires
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let sent = await transport.sentMethodsSnapshot()
        #expect(sent.contains("tools/call") == false)
        #expect(sent.contains("initialize"))   // handshake still happened
    }
}

/// One-shot await/resume barrier with no cancellation check of its own, so a task parked on
/// `wait()` stays parked (and cancellable) until `release()`.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
