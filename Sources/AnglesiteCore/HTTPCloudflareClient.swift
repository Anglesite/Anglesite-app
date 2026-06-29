import Foundation

/// Standard Cloudflare v4 response envelope.
private struct CFEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool
    let result: T?
    struct APIError: Decodable, Sendable { let message: String }
    let errors: [APIError]?
}

private struct CFZone: Decodable, Sendable {
    let id: String
    let name: String
    let status: String
}

/// Read-only Cloudflare v4 client. All methods are GETs.
public struct HTTPCloudflareClient: CloudflareReading {
    private static let base = "https://api.cloudflare.com/client/v4"
    private let transport: CloudflareTransport

    public init(transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport) {
        self.transport = transport
    }

    public static let defaultTransport: CloudflareTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudflareError.malformedResponse }
        return (data, http)
    }

    /// GET `path`, decode `CFEnvelope<T>`, return `result` or throw a mapped error.
    private func get<T: Decodable & Sendable>(_ path: String, apiToken: String, as: T.Type) async throws -> T {
        guard let url = URL(string: Self.base + path) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        let env = try JSONDecoder().decode(CFEnvelope<T>.self, from: data)
        guard env.success, let result = env.result else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "request failed")
        }
        return result
    }

    public func resolveZoneID(domain: String, apiToken: String) async throws -> String? {
        let escaped = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain
        let zones = try await get("/zones?name=\(escaped)&status=active", apiToken: apiToken, as: [CFZone].self)
        return zones.first(where: { $0.name == domain })?.id
    }

    // Implemented in Task 3.
    public func zoneState(zoneID: String, apiToken: String) async throws -> CloudflareZoneState {
        fatalError("zoneState not yet implemented — Task 3")
    }
}
