import Foundation

/// Write-side Cloudflare API seam. The concrete `HTTPCloudflareClient` talks to the
/// v4 REST API; tests provide a mock. Token is passed per call (no Keychain coupling).
public protocol CloudflareWriting: Sendable {
    func enableDNSSEC(zoneID: String, apiToken: String) async throws
    func setAlwaysUseHTTPS(zoneID: String, enabled: Bool, apiToken: String) async throws
    func setHSTS(zoneID: String, maxAge: Int, includeSubdomains: Bool, preload: Bool,
                 apiToken: String) async throws
    func addDNSRecord(zoneID: String, record: DNSRecordPayload, apiToken: String) async throws
    func setBotFightMode(zoneID: String, enabled: Bool, apiToken: String) async throws
    func createWAFCustomRule(zoneID: String, rule: WAFRulePayload, apiToken: String) async throws
}

/// Payload for creating a DNS record via the Cloudflare API.
public struct DNSRecordPayload: Sendable, Equatable, Encodable {
    public let type: String
    public let name: String
    public let content: String
    public let ttl: Int

    public init(type: String, name: String, content: String, ttl: Int = 1) {
        self.type = type
        self.name = name
        self.content = content
        self.ttl = ttl
    }
}

/// Payload for creating a custom WAF rule via the Cloudflare API.
public struct WAFRulePayload: Sendable, Equatable {
    public let description: String
    public let expression: String
    public let action: String

    public init(description: String, expression: String, action: String) {
        self.description = description
        self.expression = expression
        self.action = action
    }
}
