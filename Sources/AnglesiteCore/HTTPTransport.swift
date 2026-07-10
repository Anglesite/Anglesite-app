import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    private let bearerToken: SessionToken?

    private var sessionID: String?
    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    public init(
        endpoint: URL,
        bearerToken: SessionToken? = nil,
        protocolVersion: String = "2024-11-05",
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
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
        if let bearerToken { request.setValue("Bearer \(bearerToken.value)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message.rawValue, options: [])

        // Must not fully buffer a `text/event-stream` response: URLSession treats it as an
        // indefinite stream on a keep-alive connection, so reading the whole body (`data(for:)`)
        // never completes (it waits for the socket to close, which doesn't happen) — it hangs.
        // Both platform paths below read incrementally and return after the first complete SSE
        // event (the response to this request) without waiting for the stream to end.
        #if canImport(Darwin)
        // `bytes(for:)` gives an incremental AsyncSequence of the response body.
        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (asyncBytes, response) = try await urlSession.bytes(for: request)
        } catch {
            sessionID = nil
            throw HTTPError.sessionLost
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        #else
        // `FoundationNetworking` has no `bytes(for:)`/`AsyncBytes`; ``HTTPStreamingRunner``
        // gets the same incremental behavior via `URLSessionDataDelegate`.
        let runner = HTTPStreamingRunner()
        let response: URLResponse
        do {
            response = try await runner.start(request, configuration: urlSession.configuration)
        } catch {
            sessionID = nil
            throw HTTPError.sessionLost
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        #endif

        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
            sessionID = sid
        }

        switch http.statusCode {
        case 202:
            return  // notification accepted; no response body
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
            // Parse SSE line-by-line; emit the first complete event's data payload and return.
            // (One POSTed request yields exactly one response message on its request-scoped stream.)
            var dataLines: [String] = []
            #if canImport(Darwin)
            for try await line in asyncBytes.lines {
                if case .complete(let value) = accumulateSSELine(line, into: &dataLines) {
                    if let value { continuation.yield(value) }
                    return
                }
            }
            #else
            for try await line in runner.lines() {
                if case .complete(let value) = accumulateSSELine(line, into: &dataLines) {
                    if let value { continuation.yield(value) }
                    return
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
            if !data.isEmpty, let value = decodeData(data) { continuation.yield(value) }
        }
    }

    /// One line of SSE parsing shared by both platform read loops: accumulates `data:` payload
    /// lines, and on a blank line (event terminator) reports the decoded event so the caller can
    /// yield it and stop reading (one POSTed request yields exactly one response message).
    /// `event:`/`id:`/`retry:`/comment lines are ignored.
    private enum SSELineResult {
        case continueReading
        case complete(JSONValue?)
    }

    private func accumulateSSELine(_ line: String, into dataLines: inout [String]) -> SSELineResult {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return .continueReading }
            return .complete(decode(dataLines.joined(separator: "\n")))
        }
        if line.hasPrefix("data:") {
            let v = line.dropFirst("data:".count)
            dataLines.append(v.hasPrefix(" ") ? String(v.dropFirst()) : String(v))
        }
        return .continueReading
    }

    public nonisolated func inbound() -> AsyncStream<JSONValue> { stream }

    public func close() async {
        continuation.finish()
        // Best-effort session teardown; ignore failures.
        if let sessionID {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "DELETE"
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            if let bearerToken { request.setValue("Bearer \(bearerToken.value)", forHTTPHeaderField: "Authorization") }
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
