import Foundation

/// Standard Cloudflare v4 response envelope.
private struct CFEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool
    let result: T?
    struct APIError: Decodable, Sendable { let message: String }
    let errors: [APIError]?
}

/// Placeholder for write responses where we only check `success`.
private struct CFEmpty: Decodable, Sendable {}

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
private struct CFBotManagement: Decodable, Sendable {
    let fight_mode: Bool?
    let enable_js: Bool?
}
private struct CFRuleset: Decodable, Sendable {
    let id: String
    let phase: String?
    let rules: [CFRulesetRule]?
}
private struct CFRulesetRule: Decodable, Sendable {
    let description: String?
    let expression: String
    let action: String
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

        let botFight: Bool
        do {
            let bot = try await get("/zones/\(zoneID)/settings/bot_management", apiToken: apiToken, as: CFBotManagement.self)
            botFight = bot.fight_mode ?? false
        } catch {
            botFight = false
        }

        let wafRules = await fetchWAFCustomRules(zoneID: zoneID, apiToken: apiToken)

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
            dmarcRecords: dmarc,
            botFightMode: botFight,
            wafCustomRules: wafRules)
    }

    private func fetchWAFCustomRules(zoneID: String, apiToken: String) async -> [CloudflareZoneState.WAFCustomRule] {
        do {
            let rulesets = try await get("/zones/\(zoneID)/rulesets", apiToken: apiToken, as: [CFRuleset].self)
            guard let custom = rulesets.first(where: { $0.phase == "http_request_firewall_custom" }) else {
                return []
            }
            let full = try await get("/zones/\(zoneID)/rulesets/\(custom.id)", apiToken: apiToken, as: CFRuleset.self)
            return (full.rules ?? []).map {
                .init(description: $0.description ?? "", expression: $0.expression, action: $0.action)
            }
        } catch {
            return []
        }
    }

    // MARK: - Write helpers

    private func mutate<Body: Encodable & Sendable>(
        method: String,
        _ path: String,
        body: Body,
        apiToken: String
    ) async throws {
        guard let url = URL(string: Self.base + path) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        let env: CFEnvelope<CFEmpty>
        do {
            env = try JSONDecoder().decode(CFEnvelope<CFEmpty>.self, from: data)
        } catch {
            throw CloudflareError.malformedResponse
        }
        if !env.success {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "request failed")
        }
    }
}

// MARK: - CloudflareWriting conformance

extension HTTPCloudflareClient: CloudflareWriting {
    public func enableDNSSEC(zoneID: String, apiToken: String) async throws {
        try await mutate(method: "PUT", "/zones/\(zoneID)/dnssec",
                         body: ["status": "active"], apiToken: apiToken)
    }

    public func setAlwaysUseHTTPS(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try await mutate(method: "PUT", "/zones/\(zoneID)/settings/always_use_https",
                         body: ["value": enabled ? "on" : "off"], apiToken: apiToken)
    }

    public func setHSTS(zoneID: String, maxAge: Int, includeSubdomains: Bool, preload: Bool,
                         apiToken: String) async throws {
        struct HSTSBody: Encodable, Sendable {
            struct Value: Encodable, Sendable {
                struct STS: Encodable, Sendable {
                    let enabled: Bool
                    let max_age: Int
                    let include_subdomains: Bool
                    let preload: Bool
                }
                let strict_transport_security: STS
            }
            let value: Value
        }
        let body = HSTSBody(value: .init(strict_transport_security: .init(
            enabled: true, max_age: maxAge, include_subdomains: includeSubdomains, preload: preload)))
        try await mutate(method: "PUT", "/zones/\(zoneID)/settings/security_header",
                         body: body, apiToken: apiToken)
    }

    public func addDNSRecord(zoneID: String, record: DNSRecordPayload, apiToken: String) async throws {
        try await mutate(method: "POST", "/zones/\(zoneID)/dns_records",
                         body: record, apiToken: apiToken)
    }

    public func setBotFightMode(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try await mutate(method: "PUT", "/zones/\(zoneID)/settings/bot_management",
                         body: ["value": enabled ? "on" : "off"], apiToken: apiToken)
    }

    public func createWAFCustomRule(zoneID: String, rule: WAFRulePayload, apiToken: String) async throws {
        let rulesets = try await get("/zones/\(zoneID)/rulesets", apiToken: apiToken, as: [CFRuleset].self)
        let existing = rulesets.first(where: { $0.phase == "http_request_firewall_custom" })

        struct RuleBody: Encodable, Sendable {
            let description: String
            let expression: String
            let action: String
        }
        let ruleBody = RuleBody(description: rule.description, expression: rule.expression, action: rule.action)

        if let rs = existing {
            struct RulesAppend: Encodable, Sendable {
                let rules: [RuleBody]
            }
            try await mutate(method: "POST", "/zones/\(zoneID)/rulesets/\(rs.id)/rules",
                             body: ruleBody, apiToken: apiToken)
        } else {
            struct NewRuleset: Encodable, Sendable {
                let name: String
                let kind: String
                let phase: String
                let rules: [RuleBody]
            }
            try await mutate(method: "POST", "/zones/\(zoneID)/rulesets",
                             body: NewRuleset(name: "Anglesite security rules",
                                              kind: "zone", phase: "http_request_firewall_custom",
                                              rules: [ruleBody]),
                             apiToken: apiToken)
        }
    }
}
