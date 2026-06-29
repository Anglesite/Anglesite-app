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

private struct CFDNSSEC: Decodable, Sendable { let status: String }
private struct CFStringSetting: Decodable, Sendable { let value: String }
private struct CFSecurityHeader: Decodable, Sendable {
    struct Value: Decodable, Sendable {
        struct STS: Decodable, Sendable {
            let enabled: Bool
            let max_age: Int?
            let include_subdomains: Bool?
            let preload: Bool?
        }
        let strict_transport_security: STS
    }
    let value: Value
}
private struct CFDNSRecord: Decodable, Sendable {
    let type: String
    let name: String
    let content: String
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
        let env: CFEnvelope<T>
        do {
            env = try JSONDecoder().decode(CFEnvelope<T>.self, from: data)
        } catch {
            throw CloudflareError.malformedResponse
        }
        guard env.success, let result = env.result else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "request failed")
        }
        return result
    }

    public func resolveZoneID(domain: String, apiToken: String) async throws -> String? {
        let escaped = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain
        let zones = try await get("/zones?name=\(escaped)&status=active", apiToken: apiToken, as: [CFZone].self)
        return zones.first(where: { $0.name.lowercased() == domain.lowercased() })?.id
    }

    public func zoneState(zoneID: String, apiToken: String) async throws -> CloudflareZoneState {
        let dnssec = try await get("/zones/\(zoneID)/dnssec", apiToken: apiToken, as: CFDNSSEC.self)
        let ssl = try await get("/zones/\(zoneID)/settings/ssl", apiToken: apiToken, as: CFStringSetting.self)
        let https = try await get("/zones/\(zoneID)/settings/always_use_https", apiToken: apiToken, as: CFStringSetting.self)
        let header = try await get("/zones/\(zoneID)/settings/security_header", apiToken: apiToken, as: CFSecurityHeader.self)
        let records = try await get("/zones/\(zoneID)/dns_records?per_page=100", apiToken: apiToken, as: [CFDNSRecord].self)

        let sts = header.value.strict_transport_security
        let hsts: CloudflareZoneState.HSTS? = sts.enabled
            ? .init(maxAge: sts.max_age ?? 0, includeSubdomains: sts.include_subdomains ?? false, preload: sts.preload ?? false)
            : nil

        func contents(ofType t: String) -> [String] {
            records.filter { $0.type.uppercased() == t }.map(\.content)
        }
        let txt = records.filter { $0.type.uppercased() == "TXT" }
        let spf = txt.filter { $0.content.lowercased().hasPrefix("v=spf1") }.map(\.content)
        let dmarc = txt.filter { $0.name.lowercased().hasPrefix("_dmarc.") && $0.content.lowercased().hasPrefix("v=dmarc1") }.map(\.content)

        return CloudflareZoneState(
            dnssecActive: dnssec.status.lowercased() == "active",
            sslMode: ssl.value,
            alwaysUseHTTPS: https.value.lowercased() == "on",
            hsts: hsts,
            caaRecords: contents(ofType: "CAA"),
            mxRecords: contents(ofType: "MX"),
            spfRecords: spf,
            dmarcRecords: dmarc)
    }
}
