import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `ACPTransport` over plain HTTP: each `send` POSTs one JSON-RPC message to the configured
/// endpoint. A plain `application/json` response is read as a single bounded body and decoded
/// once. A `text/event-stream` response is read incrementally, and — unlike MCP's `HTTPTransport`,
/// where one POST always yields exactly one response message on its request-scoped stream — MAY
/// carry multiple JSON-RPC messages on that same stream: zero or more `session/update` push
/// notifications followed eventually by the final JSON-RPC response to the POSTed request. So the
/// SSE read loop below yields every complete event as it's parsed and only stops when the
/// underlying stream itself ends, instead of returning after the first event.
/// `ACPClient.consumeInbound` already routes each yielded message correctly regardless of order —
/// a notification (no "id") to `routeSessionUpdate`, a response (has "id") to `resolvePending`.
public actor ACPHTTPTransport: ACPTransport {
    public enum HTTPError: Error, Sendable, Equatable {
        case http(status: Int)
        case badResponse
    }

    private let endpoint: URL
    private let bearerToken: SessionToken?
    private let urlSession: URLSession
    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    public init(endpoint: URL, bearerToken: SessionToken? = nil, urlSession: URLSession = .shared) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.urlSession = urlSession
        (self.stream, self.continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
    }

    public func open() async throws { /* no persistent connection; first send does the work */ }

    public func send(_ message: JSONValue) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken.value)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message.rawValue)

        // Must not fully buffer a `text/event-stream` response: URLSession treats it as an
        // indefinite stream on a keep-alive connection, so reading the whole body (`data(for:)`)
        // never completes (it waits for the socket to close, which doesn't happen) — it hangs.
        // Both platform paths below read incrementally.
        #if canImport(Darwin)
        // `bytes(for:)` gives an incremental AsyncSequence of the response body.
        let (asyncBytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        #else
        // `FoundationNetworking` has no `bytes(for:)`/`AsyncBytes`; ``HTTPStreamingRunner``
        // gets the same incremental behavior via `URLSessionDataDelegate`.
        let runner = HTTPStreamingRunner()
        let response = try await runner.start(request, configuration: urlSession.configuration)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        #endif

        guard (200...299).contains(http.statusCode) else { throw HTTPError.http(status: http.statusCode) }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            // A single POSTed request's SSE stream may carry MULTIPLE messages — zero or more
            // `session/update` notifications, then the final response to this request. Yield
            // every complete event as it's parsed; keep reading until the stream itself ends.
            var dataLines: [String] = []
            #if canImport(Darwin)
            for try await line in asyncBytes.lines {
                if case .complete(let value) = accumulateSSELine(line, into: &dataLines) {
                    if let value { continuation.yield(value) }
                }
            }
            #else
            for try await line in runner.lines() {
                if case .complete(let value) = accumulateSSELine(line, into: &dataLines) {
                    if let value { continuation.yield(value) }
                }
            }
            #endif
            // Stream ended without a trailing blank line — flush whatever accumulated.
            if !dataLines.isEmpty, let value = decode(dataLines.joined(separator: "\n")) {
                continuation.yield(value)
            }
        } else {
            // application/json (or other): accumulate the bounded body and decode one message.
            var data = Data()
            #if canImport(Darwin)
            for try await byte in asyncBytes { data.append(byte) }
            #else
            for try await chunk in runner.bodyStream { data.append(chunk) }
            #endif
            // A notification (no "id") may legitimately get an empty body back — nothing to decode.
            guard !data.isEmpty else { return }
            guard let value = decodeData(data) else { throw HTTPError.badResponse }
            continuation.yield(value)
        }
    }

    /// One line of SSE parsing shared by both platform read loops: accumulates `data:` payload
    /// lines, and on a blank line (event terminator) reports the decoded event. `event:`/`id:`/
    /// `retry:`/comment lines are ignored.
    private enum SSELineResult {
        case continueReading
        case complete(JSONValue?)
    }

    private func accumulateSSELine(_ line: String, into dataLines: inout [String]) -> SSELineResult {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return .continueReading }
            let joined = dataLines.joined(separator: "\n")
            dataLines = []
            return .complete(decode(joined))
        }
        if line.hasPrefix("data:") {
            let v = line.dropFirst("data:".count)
            dataLines.append(v.hasPrefix(" ") ? String(v.dropFirst()) : String(v))
        }
        return .continueReading
    }

    public nonisolated func inbound() -> AsyncStream<JSONValue> { stream }

    public func close() async { continuation.finish() }

    private func decode(_ payload: String) -> JSONValue? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return decodeData(data)
    }

    private func decodeData(_ data: Data) -> JSONValue? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue.from(raw)
    }
}
