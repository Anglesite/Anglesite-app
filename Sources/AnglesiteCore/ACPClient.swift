// Sources/AnglesiteCore/ACPClient.swift
import Foundation

/// JSON-RPC 2.0 client speaking the Agent Client Protocol (ACP) over a pluggable `ACPTransport`.
///
/// Differs from `MCPClient` in one important way: MCP discards every server notification, but ACP
/// notifications (`session/update`) and server-initiated requests (`session/request_permission`)
/// carry the actual conversation content and must be acted on. This client owns id-correlation for
/// request/response pairs (like `MCPClient`) plus routing `session/update` to the matching
/// in-flight `sendPrompt` call, and auto-declines any `session/request_permission` — this slice
/// has no tool-permission UI (see the ACP agent settings design spec §4.4/§5), so an agent that
/// attempts a tool call during the proof-of-concept turn is told "no" rather than left hanging.
public actor ACPClient {
    public enum ACPError: Error, Sendable, Equatable {
        case invalidResponse(String)
        case rpcError(code: Int, message: String)
        /// A call was made after `stop()` (or before the client has ever started). Mirrors
        /// `MCPClient.MCPError.notInitialized` — fail fast instead of registering a pending
        /// continuation against a closed transport that will never answer.
        case stopped
    }

    private let transport: any ACPTransport
    private var readerTask: Task<Void, Never>?
    private var nextRequestID: Int = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    /// Set at the start of `stop()`; guards `sendRequest`/`sendNotification` against sending on an
    /// already-closed transport (see `MCPClient.transport == nil` for the equivalent guard).
    private var isStopped: Bool = false
    /// One live `session/update` listener per session — this slice only ever drives one turn at a
    /// time per `ACPAssistant`, so a single continuation per session id is sufficient.
    private var sessionUpdateContinuations: [String: AsyncStream<AssistantEvent>.Continuation] = [:]

    public init(transport: any ACPTransport) {
        self.transport = transport
    }

    public func initialize() async throws {
        try await transport.open()
        readerTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeInbound(transport.inbound())
        }
        let params: JSONValue = .object([
            "protocolVersion": .int(1),
            "clientCapabilities": .object(["fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)])]),
        ])
        _ = try await sendRequest(method: "initialize", params: params)
    }

    public func newSession(cwd: String) async throws -> String {
        let result = try await sendRequest(method: "session/new", params: .object(["cwd": .string(cwd), "mcpServers": .array([])]))
        guard case .object(let obj) = result, case .string(let sessionID)? = obj["sessionId"] else {
            throw ACPError.invalidResponse("session/new missing 'sessionId'")
        }
        return sessionID
    }

    /// Streams one turn as `AssistantEvent`s: `.started` immediately, `.textDelta`/`.toolUse`/
    /// `.toolResult` as `session/update` notifications arrive for `sessionID`, then `.turnComplete`
    /// (or `.failed`) once the `session/prompt` response itself resolves.
    public func sendPrompt(sessionID: String, text: String) async throws -> AsyncStream<AssistantEvent> {
        let (stream, continuation) = AsyncStream<AssistantEvent>.makeStream(bufferingPolicy: .unbounded)
        sessionUpdateContinuations[sessionID] = continuation
        continuation.yield(.started(model: nil, toolNames: []))

        let params: JSONValue = .object([
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ])
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sendRequest(method: "session/prompt", params: params)
                continuation.yield(.turnComplete(nil))
            } catch {
                continuation.yield(.failed(message: String(describing: error)))
            }
            await self.finishSessionUpdates(sessionID: sessionID)
            continuation.finish()
        }
        return stream
    }

    public func cancelSession(sessionID: String) async {
        try? await sendNotification(method: "session/cancel", params: .object(["sessionId": .string(sessionID)]))
    }

    public func stop() async {
        isStopped = true
        readerTask?.cancel()
        readerTask = nil
        await transport.close()
        for (_, cont) in pending { cont.resume(throwing: CancellationError()) }
        pending.removeAll()
        for cont in sessionUpdateContinuations.values { cont.finish() }
        sessionUpdateContinuations.removeAll()
    }

    // MARK: Internals

    private func finishSessionUpdates(sessionID: String) {
        sessionUpdateContinuations.removeValue(forKey: sessionID)
    }

    private func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        guard !isStopped else { throw ACPError.stopped }
        let id = nextRequestID
        nextRequestID += 1
        var obj: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": .int(id), "method": .string(method)]
        if let params { obj["params"] = params }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            pending[id] = cont
            Task { [weak self] in
                do {
                    try await self?.transport.send(.object(obj))
                } catch {
                    await self?.failPending(id: id, error: error)
                }
            }
        }
    }

    private func sendNotification(method: String, params: JSONValue?) async throws {
        guard !isStopped else { throw ACPError.stopped }
        var obj: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { obj["params"] = params }
        try await transport.send(.object(obj))
    }

    private func failPending(id: Int, error: Error) {
        if let cont = pending.removeValue(forKey: id) { cont.resume(throwing: error) }
    }

    private func resolvePending(id: Int, value: JSONValue) {
        if let cont = pending.removeValue(forKey: id) { cont.resume(returning: value) }
    }

    private func consumeInbound(_ stream: AsyncStream<JSONValue>) async {
        for await message in stream {
            guard case .object(let obj) = message else { continue }

            if case .string(let method)? = obj["method"] {
                if case .int(let id)? = obj["id"] {
                    // Server-initiated request. Only `session/request_permission` is expected this
                    // slice; auto-decline since there is no tool-permission UI yet.
                    if method == "session/request_permission" {
                        try? await transport.send(.object([
                            "jsonrpc": .string("2.0"), "id": .int(id),
                            "result": .object(["outcome": .object(["outcome": .string("cancelled")])]),
                        ]))
                    }
                    continue
                }
                if method == "session/update" { routeSessionUpdate(obj["params"]) }
                continue
            }

            guard case .int(let id)? = obj["id"] else { continue }  // response
            if case .object(let errObj)? = obj["error"] {
                let code: Int = { if case .int(let c)? = errObj["code"] { return c }; return -1 }()
                let msg: String = { if case .string(let m)? = errObj["message"] { return m }; return "unknown rpc error" }()
                failPending(id: id, error: ACPError.rpcError(code: code, message: msg))
            } else {
                resolvePending(id: id, value: obj["result"] ?? .null)
            }
        }
    }

    private func routeSessionUpdate(_ params: JSONValue?) {
        guard case .object(let params)? = params,
              case .string(let sessionID)? = params["sessionId"],
              case .object(let update)? = params["update"],
              case .string(let kind)? = update["sessionUpdate"],
              let continuation = sessionUpdateContinuations[sessionID]
        else { return }

        switch kind {
        case "agent_message_chunk":
            if case .object(let content)? = update["content"], case .string(let text)? = content["text"] {
                continuation.yield(.textDelta(text))
            }
        case "agent_thought_chunk":
            if case .object(let content)? = update["content"], case .string(let text)? = content["text"] {
                continuation.yield(.thinking(text))
            }
        case "tool_call":
            let id: String = { if case .string(let s)? = update["toolCallId"] { return s }; return UUID().uuidString }()
            let name: String = { if case .string(let s)? = update["title"] { return s }; return "tool" }()
            continuation.yield(.toolUse(id: id, name: name, input: .null))
        case "tool_call_update":
            guard case .string(let id)? = update["toolCallId"] else { return }
            let status: String = { if case .string(let s)? = update["status"] { return s }; return "" }()
            continuation.yield(.toolResult(id: id, content: status, isError: status == "failed"))
        default:
            break  // unrecognized update kind — safely ignored
        }
    }
}
