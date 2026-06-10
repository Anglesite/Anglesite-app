import Foundation

/// Parses Server-Sent Events framing into the `data:` payloads. MCP Streamable HTTP carries one
/// JSON-RPC message per SSE event. We only need the `data` field; `event:`/`id:`/`retry:` are
/// ignored. A blank line dispatches the accumulated event; a trailing event without a final blank
/// line is still emitted.
enum SSEFrameParser {
    static func dataPayloads(in text: String) -> [String] {
        var payloads: [String] = []
        var dataLines: [String] = []

        func flush() {
            if !dataLines.isEmpty {
                payloads.append(dataLines.joined(separator: "\n"))
                dataLines.removeAll()
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("data:") {
                let value = line.dropFirst("data:".count)
                dataLines.append(value.hasPrefix(" ") ? String(value.dropFirst()) : String(value))
            }
            // Other fields (event:, id:, retry:, comments starting with ':') are ignored.
        }
        flush()
        return payloads
    }
}

/// `MCPTransport` over MCP Streamable HTTP. Each `send` POSTs one JSON-RPC message to the `/mcp`
/// endpoint; the response (single `application/json` object, or one-or-more messages over a
/// request-scoped `text/event-stream`) is decoded and funneled into `inbound()`. The session id
/// returned by `initialize` is captured and replayed on every subsequent request. A `404`/refused
/// connection clears the session so a future re-`initialize` can recover (full container-restart
/// recovery lands with #66/#69).
public actor HTTPTransport: MCPTransport {
    public enum HTTPError: Error, Sendable, Equatable {
        case http(status: Int)
        case sessionLost
        case badResponse
    }

    private let endpoint: URL
    private let protocolVersion: String
    private let urlSession: URLSession

    private var sessionID: String?
    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    public init(
        endpoint: URL,
        protocolVersion: String = "2024-11-05",
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.protocolVersion = protocolVersion
        self.urlSession = urlSession
        (self.stream, self.continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
    }

    public func open() async throws { /* no persistent connection; first send does the work */ }

    public func send(_ message: JSONValue) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message.rawValue, options: [])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            sessionID = nil
            throw HTTPError.sessionLost
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }

        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
            sessionID = sid
        }

        switch http.statusCode {
        case 202:
            return  // notification accepted; no body
        case 404:
            sessionID = nil
            throw HTTPError.sessionLost
        case 200:
            break
        default:
            throw HTTPError.http(status: http.statusCode)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            let text = String(decoding: data, as: UTF8.self)
            for payload in SSEFrameParser.dataPayloads(in: text) {
                if let value = decode(payload) { continuation.yield(value) }
            }
        } else if data.isEmpty {
            return
        } else {
            if let value = decodeData(data) { continuation.yield(value) }
        }
    }

    public nonisolated func inbound() -> AsyncStream<JSONValue> { stream }

    public func close() async {
        continuation.finish()
        // Best-effort session teardown; ignore failures.
        if let sessionID {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "DELETE"
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await urlSession.data(for: request)
        }
        sessionID = nil
    }

    private func decode(_ payload: String) -> JSONValue? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return decodeData(data)
    }

    private func decodeData(_ data: Data) -> JSONValue? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue.from(raw)
    }
}
