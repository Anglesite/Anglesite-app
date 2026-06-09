import Foundation

/// Minimal JSON value used at the MCP boundary so request/response shapes stay `Sendable` and
/// `Equatable` without forcing every caller to define a `Codable` model.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Convert to a `JSONSerialization`-friendly value tree.
    public var rawValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.rawValue)
        case .object(let o): return o.mapValues(\.rawValue)
        }
    }

    /// Convert a `JSONSerialization` result tree into a `JSONValue`. Returns `nil` for shapes
    /// containing unsupported types (e.g. dictionary keys that aren't strings).
    public static func from(_ value: Any) -> JSONValue? {
        if value is NSNull { return .null }
        if let s = value as? String { return .string(s) }
        // NSNumber must be checked BEFORE Bool/Int/Double casts — `NSNumber(1) as? Bool`
        // succeeds, which would silently turn integer 1 into .bool(true).
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            // JSONSerialization uses NSNumber for both ints and doubles; pick based on the
            // CFNumber type so 1.0 stays a double and 1 stays an int.
            let typeChar = String(cString: n.objCType)
            if typeChar == "d" || typeChar == "f" {
                return .double(n.doubleValue)
            }
            return .int(n.intValue)
        }
        if let a = value as? [Any] {
            var out: [JSONValue] = []
            for v in a { guard let jv = JSONValue.from(v) else { return nil }; out.append(jv) }
            return .array(out)
        }
        if let o = value as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in o { guard let jv = JSONValue.from(v) else { return nil }; out[k] = jv }
            return .object(out)
        }
        return nil
    }
}

/// JSON-RPC 2.0 client speaking the Model Context Protocol over stdio.
///
/// Phase 3 surface is intentionally narrow: `start(...)` spawns the server and runs the
/// `initialize` handshake; `listTools()` and `callTool(name:arguments:)` cover what the
/// app actually needs in v0. Notifications from the server (no `id`) are discarded — Phase 5
/// will revisit this when `apply-edit` round-trips need richer routing.
///
/// All stdout from the supervised server flows through `LogCenter` (so the Debug pane can see
/// the protocol traffic). The client subscribes to that same `LogCenter` and parses lines
/// matching its source tag.
public actor MCPClient {
    public enum MCPError: Error, Sendable, Equatable {
        case notInitialized
        case alreadyRunning
        case invalidResponse(String)
        case rpcError(code: Int, message: String)
        case exitedBeforeReady(ProcessSupervisor.ExitReason)
        case timeout
        /// In-flight request failed because the server process crashed and is being restarted;
        /// the client re-runs `initialize` against the fresh process. Retry the call.
        case reconnecting
    }

    public struct ToolDescriptor: Sendable, Equatable {
        public let name: String
        public let description: String?
        public let inputSchema: JSONValue?
    }

    public struct ToolCallResult: Sendable, Equatable {
        public let content: [Content]
        public let isError: Bool

        public init(content: [Content], isError: Bool) {
            self.content = content
            self.isError = isError
        }

        public struct Content: Sendable, Equatable {
            public let type: String
            public let text: String?

            public init(type: String, text: String?) {
                self.type = type
                self.text = text
            }
        }
    }

    private let supervisor: ProcessSupervisor
    private let logCenter: LogCenter

    private var handle: ProcessSupervisor.Handle?
    private var subscription: LogCenter.Subscription?
    private var readerTask: Task<Void, Never>?
    private var source: String = ""

    private var nextRequestID: Int = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var initialized: Bool = false

    // Captured from `start(...)` so a respawn can re-run the same `initialize` handshake.
    private var clientName: String = "Anglesite"
    private var clientVersion: String = "0.1.0"
    private var initializeTimeout: TimeInterval = 10

    public init(supervisor: ProcessSupervisor, logCenter: LogCenter = .shared) {
        self.supervisor = supervisor
        self.logCenter = logCenter
    }

    public var isRunning: Bool { handle != nil }

    /// Spawn the MCP server and run the `initialize` handshake. Returns once the server has
    /// responded with its capabilities. If the server later crashes, `ProcessSupervisor` restarts
    /// it per `restartPolicy` and the client re-runs `initialize` against the fresh process; calls
    /// that were in flight at the moment of the crash fail with `MCPError.reconnecting`.
    public func start(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        source: String = "mcp",
        currentDirectoryURL: URL? = nil,
        restartPolicy: ProcessSupervisor.RestartPolicy = .onCrash(maxAttempts: 3, baseBackoff: 1.0),
        initializeTimeout: TimeInterval = 10,
        clientName: String = "Anglesite",
        clientVersion: String = "0.1.0"
    ) async throws {
        if handle != nil { throw MCPError.alreadyRunning }
        self.source = source
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.initializeTimeout = initializeTimeout

        let sub = await logCenter.subscribe()
        self.subscription = sub

        let h = try await supervisor.launch(
            source: source,
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            restartPolicy: restartPolicy,
            attachStdin: true,
            onRespawn: { [weak self] in await self?.handleRespawn() },
            logCenter: logCenter
        )
        self.handle = h

        // Start the reader before we send anything so we don't lose an early response.
        readerTask = Task { [weak self] in
            await self?.consumeResponses(sub.stream, source: source)
        }

        do {
            try await runInitializeHandshake()
            self.initialized = true
        } catch {
            await teardown()
            throw error
        }
    }

    /// Sends `initialize` (and the required `notifications/initialized` follow-up). Used both at
    /// `start(...)` and after a supervised respawn.
    private func runInitializeHandshake() async throws {
        let params: JSONValue = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ])
        _ = try await sendRequest(method: "initialize", params: params, timeout: initializeTimeout)
        // Notifications expect no response and the server may not care — ignore failure.
        try? await sendNotification(method: "notifications/initialized", params: nil)
    }

    /// Fired by `ProcessSupervisor` after it restarts the crashed server. The old stdin is gone
    /// (`writeJSONLine` writes by `Handle` through the supervisor, which targets the fresh pipe) and
    /// any in-flight requests can never be answered — fail them, drop `initialized`, then re-handshake.
    private func handleRespawn() async {
        let waiters = pending
        pending.removeAll()
        for cont in waiters.values { cont.resume(throwing: MCPError.reconnecting) }
        initialized = false
        do {
            try await runInitializeHandshake()
            initialized = true
        } catch {
            // Reconnect failed; stays un-initialized. The next call throws `.notInitialized`.
        }
    }

    public func listTools() async throws -> [ToolDescriptor] {
        guard initialized else { throw MCPError.notInitialized }
        let result = try await sendRequest(method: "tools/list", params: .object([:]), timeout: 5)
        guard case .object(let dict) = result, case .array(let tools)? = dict["tools"] else {
            throw MCPError.invalidResponse("tools/list missing 'tools' array")
        }
        return tools.compactMap { entry -> ToolDescriptor? in
            guard case .object(let obj) = entry, case .string(let name)? = obj["name"] else { return nil }
            let desc: String? = {
                if case .string(let s)? = obj["description"] { return s }
                return nil
            }()
            return ToolDescriptor(name: name, description: desc, inputSchema: obj["inputSchema"])
        }
    }

    public func callTool(name: String, arguments: JSONValue = .object([:])) async throws -> ToolCallResult {
        guard initialized else { throw MCPError.notInitialized }
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments,
        ])
        let result = try await sendRequest(method: "tools/call", params: params, timeout: 30)
        guard case .object(let dict) = result else {
            throw MCPError.invalidResponse("tools/call result not an object")
        }
        let isError: Bool = {
            if case .bool(let b)? = dict["isError"] { return b }
            return false
        }()
        var contents: [ToolCallResult.Content] = []
        if case .array(let items)? = dict["content"] {
            for item in items {
                guard case .object(let obj) = item, case .string(let type)? = obj["type"] else { continue }
                let text: String? = {
                    if case .string(let s)? = obj["text"] { return s }
                    return nil
                }()
                contents.append(ToolCallResult.Content(type: type, text: text))
            }
        }
        return ToolCallResult(content: contents, isError: isError)
    }

    public func stop() async {
        await teardown()
    }

    // MARK: Internals

    private func sendRequest(
        method: String,
        params: JSONValue?,
        timeout: TimeInterval
    ) async throws -> JSONValue {
        let id = nextRequestID
        nextRequestID += 1

        var obj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
        ]
        if let params { obj["params"] = params }

        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
                    Task { [weak self] in
                        await self?.registerPending(id: id, continuation: cont)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                throw MCPError.timeout
            }

            do {
                try await writeJSONLine(.object(obj))
            } catch {
                group.cancelAll()
                throw error
            }

            do {
                guard let first = try await group.next() else {
                    group.cancelAll()
                    failPending(id: id, error: MCPError.timeout)
                    throw MCPError.timeout
                }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                failPending(id: id, error: error)
                throw error
            }
        }
    }

    private func sendNotification(method: String, params: JSONValue?) async throws {
        var obj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { obj["params"] = params }
        try await writeJSONLine(.object(obj))
    }

    private func writeJSONLine(_ value: JSONValue) async throws {
        guard let handle = self.handle else {
            throw MCPError.notInitialized
        }
        var data = try JSONSerialization.data(withJSONObject: value.rawValue, options: [])
        data.append(0x0A)  // '\n' — one JSON object per line; framing must be byte-identical.
        // Route through the supervisor's `writeStdin` so this works for both backends: the
        // in-process backend writes to the child's stdin pipe; the XPC backend forwards the bytes
        // to the helper (a live FileHandle can't cross the XPC boundary).
        do {
            try await supervisor.writeStdin(handle, data)
        } catch {
            throw MCPError.notInitialized
        }
    }

    private func registerPending(id: Int, continuation: CheckedContinuation<JSONValue, Error>) {
        pending[id] = continuation
    }

    private func failPending(id: Int, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func resolvePending(id: Int, value: JSONValue) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(returning: value)
        }
    }

    private func consumeResponses(_ stream: AsyncStream<LogCenter.LogLine>, source: String) async {
        for await line in stream {
            guard line.source == source, line.stream == .stdout else { continue }
            guard let data = line.text.data(using: .utf8) else { continue }
            // MCP frames are one JSON object per line — skip lines that aren't JSON (the server
            // may emit incidental log output before/during startup).
            guard let raw = try? JSONSerialization.jsonObject(with: data),
                  let obj = raw as? [String: Any]
            else { continue }

            // We only care about responses (have an `id` and either `result` or `error`).
            guard let id = obj["id"] as? Int else { continue }

            if let errObj = obj["error"] as? [String: Any] {
                let code = (errObj["code"] as? Int) ?? -1
                let message = (errObj["message"] as? String) ?? "unknown rpc error"
                failPending(id: id, error: MCPError.rpcError(code: code, message: message))
                continue
            }
            if let result = obj["result"], let value = JSONValue.from(result) {
                resolvePending(id: id, value: value)
            } else {
                resolvePending(id: id, value: .null)
            }
        }
    }

    private func teardown() async {
        subscription?.cancel()
        subscription = nil
        readerTask?.cancel()
        readerTask = nil
        if let h = handle {
            await supervisor.terminate(h, timeout: 2)
            _ = await supervisor.waitForExit(h)
        }
        handle = nil
        initialized = false
        // Fail outstanding requests.
        for (_, cont) in pending {
            cont.resume(throwing: MCPError.notInitialized)
        }
        pending.removeAll()
    }
}
