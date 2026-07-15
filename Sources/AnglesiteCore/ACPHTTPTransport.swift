import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `ACPTransport` over plain HTTP: each `send` POSTs one JSON-RPC message to the configured
/// endpoint and decodes its `application/json` response directly into `inbound()`. Unlike MCP's
/// `HTTPTransport`, this slice does not implement an SSE read path — a remote ACP agent's
/// `session/update` push notifications are a fast-follow (see the ACP agent settings design spec
/// §4.3); every response this transport sees is a direct reply to the request that produced it.
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
        if let bearerToken {
            request.setValue("Bearer \(bearerToken.value)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message.rawValue)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw HTTPError.http(status: http.statusCode) }
        // A notification (no "id") may legitimately get an empty body back — nothing to decode.
        guard !data.isEmpty else { return }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let value = JSONValue.from(raw) else { throw HTTPError.badResponse }
        continuation.yield(value)
    }

    public nonisolated func inbound() -> AsyncStream<JSONValue> { stream }

    public func close() async { continuation.finish() }
}
