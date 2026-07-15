import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Outcome of one webmention send attempt for a single (source, target) pair.
public enum WebmentionSendOutcome: Equatable, Sendable {
    case sent(endpoint: URL, statusCode: Int)
    case noEndpointDiscovered
    case requestFailed(reason: String)
}

/// Sends one Webmention: discovers `target`'s declared endpoint via `WebmentionEndpointDiscovery`,
/// then POSTs `source`+`target` form-encoded per the webmention.org spec. No retry logic here —
/// a caller that doesn't record a `.requestFailed` pair as sent gets a free retry on its next
/// pass (see `WebmentionSendCommand`).
public enum WebmentionSender {
    public static func send(
        source: URL,
        target: URL,
        transport: WebmentionEndpointDiscovery.Transport
    ) async -> WebmentionSendOutcome {
        let endpoint: URL?
        do {
            endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport)
        } catch {
            return .requestFailed(reason: "endpoint discovery failed: \(error)")
        }
        guard let endpoint else { return .noEndpointDiscovered }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "source=\(formEncode(source.absoluteString))&target=\(formEncode(target.absoluteString))"
        request.httpBody = Data(body.utf8)

        let http: HTTPURLResponse
        do {
            (_, http) = try await transport(request)
        } catch {
            return .requestFailed(reason: "POST to \(endpoint.absoluteString) failed: \(error)")
        }
        guard (200..<300).contains(http.statusCode) else {
            return .requestFailed(reason: "\(endpoint.absoluteString) returned HTTP \(http.statusCode)")
        }
        return .sent(endpoint: endpoint, statusCode: http.statusCode)
    }

    /// Percent-encodes everything but RFC 3986 unreserved characters, so a source/target URL's
    /// own `:`, `/`, `?`, `&`, `=` can't be mistaken for the outer form body's delimiters.
    private static func formEncode(_ value: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
