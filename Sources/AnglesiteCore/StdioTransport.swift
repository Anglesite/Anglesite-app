import Foundation

/// `MCPTransport` over a supervised subprocess's stdio (today's only transport). `send` writes a
/// newline-framed JSON object to the child's stdin via the supervisor; `inbound()` yields each
/// stdout line (filtered to this transport's `source`) parsed as a `JSONValue`. On a supervised
/// respawn the supervisor calls `onReconnect`, which `MCPClient` uses to re-run its handshake.
public actor StdioTransport: MCPTransport {
    private let supervisor: ProcessSupervisor
    private let logCenter: LogCenter
    private let source: String
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let currentDirectoryURL: URL?
    private let restartPolicy: ProcessSupervisor.RestartPolicy
    private let onReconnect: @Sendable () async -> Void

    private var handle: ProcessSupervisor.Handle?
    private var subscription: LogCenter.Subscription?
    private var forwardTask: Task<Void, Never>?

    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    public init(
        supervisor: ProcessSupervisor,
        logCenter: LogCenter,
        source: String,
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        restartPolicy: ProcessSupervisor.RestartPolicy,
        onReconnect: @escaping @Sendable () async -> Void
    ) {
        self.supervisor = supervisor
        self.logCenter = logCenter
        self.source = source
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.restartPolicy = restartPolicy
        self.onReconnect = onReconnect
        (self.stream, self.continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
    }

    public func open() async throws {
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
            onRespawn: { [onReconnect] in await onReconnect() },
            logCenter: logCenter
        )
        self.handle = h
        // Forward parsed stdout frames into the inbound stream. Captures only value types + the
        // subscription stream — no `self` — so the task doesn't keep the transport alive.
        forwardTask = Task { [source, continuation] in
            for await line in sub.stream {
                guard line.source == source, line.stream == .stdout else { continue }
                guard let data = line.text.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data),
                      let value = JSONValue.from(raw)
                else { continue }
                continuation.yield(value)
            }
        }
    }

    public func send(_ message: JSONValue) async throws {
        guard let handle else { throw MCPClient.MCPError.notInitialized }
        var data = try JSONSerialization.data(withJSONObject: message.rawValue, options: [])
        data.append(0x0A)  // '\n' — one JSON object per line; framing must be byte-identical.
        do {
            try await supervisor.writeStdin(handle, data)
        } catch {
            throw MCPClient.MCPError.notInitialized
        }
    }

    public nonisolated func inbound() -> AsyncStream<JSONValue> { stream }

    public func close() async {
        forwardTask?.cancel()
        forwardTask = nil
        subscription?.cancel()
        subscription = nil
        if let h = handle {
            await supervisor.terminate(h, timeout: 2)
            _ = await supervisor.waitForExit(h)
        }
        handle = nil
        continuation.finish()
    }
}
