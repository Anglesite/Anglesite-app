import Foundation

/// `ACPTransport` over a local ACP agent process running inside the site's own container —
/// launched via `LocalContainerControl.execInteractive`, alongside the dev server and MCP sidecar
/// (not a host `ProcessSupervisor` subprocess; see the ACP agent settings design spec §3 for why
/// neither existing `MCPTransport` conformer fits this). Each `send` writes one newline-framed
/// JSON-RPC message to the guest process's stdin; `inbound()` parses each stdout line as a
/// `JSONValue`. Every line on BOTH streams also flows to `LogCenter` ("logs are sacred" — every
/// spawned subprocess streams stdout+stderr into the debug pane, matching `StdioTransport`'s
/// existing MCP protocol-traffic-is-visible precedent), tagged `source: "acp:<siteID>"`.
public actor ACPContainerExecTransport: ACPTransport {
    private let control: any LocalContainerControl
    private let siteID: String
    private let command: String
    private let arguments: [String]
    private let workingDirectory: String
    private let logCenter: LogCenter

    private var handle: InteractiveExecHandle?
    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    public init(
        control: any LocalContainerControl,
        siteID: String,
        command: String,
        arguments: [String],
        workingDirectory: String = "/workspace/site",
        logCenter: LogCenter = .shared
    ) {
        self.control = control
        self.siteID = siteID
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.logCenter = logCenter
        (self.stream, self.continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
    }

    public func open() async throws {
        let logSource = "acp:\(siteID)"
        handle = try await control.execInteractive(
            siteID: siteID,
            argv: [command] + arguments,
            environment: [:],
            workingDirectory: workingDirectory,
            onOutput: { [continuation, logCenter] line, stream in
                Task { await logCenter.append(source: logSource, stream: stream, text: line) }
                guard stream == .stdout else { return }
                guard let data = line.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data),
                      let value = JSONValue.from(raw) else { return }
                continuation.yield(value)
            }
        )
    }

    public func send(_ message: JSONValue) async throws {
        guard let handle else { throw ACPTransportError.notOpen }
        let data = try JSONSerialization.data(withJSONObject: message.rawValue)
        try await handle.write(data + Data("\n".utf8))
    }

    public nonisolated func inbound() -> AsyncStream<JSONValue> { stream }

    public func close() async {
        await handle?.terminate()
        continuation.finish()
    }
}

public enum ACPTransportError: Error, Sendable, Equatable {
    case notOpen
}
