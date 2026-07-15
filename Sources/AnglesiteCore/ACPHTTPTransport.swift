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
/// SSE read loop below yields every complete event as it's parsed, and stops as soon as it sees
/// the response whose `id` matches the outgoing request — not by waiting for the underlying
/// stream/connection to end, which isn't a safe termination signal (see `send`'s `requestID`
/// doc comment for why).
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
        // The id of the outgoing request, if any (absent for notifications). Used below to stop
        // reading the SSE stream as soon as the matching response arrives, rather than waiting for
        // the connection itself to close — the latter is not guaranteed to happen promptly (some
        // servers/proxies keep a connection idle-open after finishing a response), and in test
        // doubles built on a custom `URLProtocol`, `bytes(for:)`'s `AsyncBytes` iterator may never
        // observe end-of-stream at all even after the response has fully "finished loading" from
        // the protocol's own point of view — waiting for that would hang indefinitely.
        let requestID: JSONValue? = {
            if case .object(let obj) = message { return obj["id"] }
            return nil
        }()

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
            // `session/update` notifications, then the final response to this request. Yield every
            // complete event as it's parsed, and stop as soon as we see the response matching
            // `requestID` (rather than waiting for the stream/connection to end — see the doc
            // comment on `requestID` above for why that isn't a safe termination condition).
            var dataLines: [String] = []
            #if canImport(Darwin)
            for try await line in asyncBytes.lines {
                if case .complete(let value) = accumulateSSELine(line, into: &dataLines) {
                    guard let value else { continue }
                    continuation.yield(value)
                    if isMatchingResponse(value, requestID: requestID) { return }
                }
            }
            #else
            for try await line in runner.lines() {
                if case .complete(let value) = accumulateSSELine(line, into: &dataLines) {
                    guard let value else { continue }
                    continuation.yield(value)
                    if isMatchingResponse(value, requestID: requestID) { return }
                }
            }
            #endif
            // Stream ended without a trailing blank line (or without ever seeing the matching
            // response) — flush whatever accumulated so a well-formed final event isn't lost.
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

    /// True when `value` is a JSON-RPC response (has `result` or `error`) whose `id` matches
    /// `requestID` — i.e. it's the reply to the request this `send` call POSTed, as opposed to a
    /// `session/update` notification (no `id`) or a response to some other in-flight request.
    /// `requestID` is `nil` for a notification POST, which never matches anything (notifications
    /// get no reply, so this always falls through to reading until the stream ends).
    private func isMatchingResponse(_ value: JSONValue, requestID: JSONValue?) -> Bool {
        guard let requestID, case .object(let obj) = value, let id = obj["id"], id == requestID else { return false }
        return obj["result"] != nil || obj["error"] != nil
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
