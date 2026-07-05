import Foundation

/// Errors surfaced by the Cloudflare read client.
public enum CloudflareError: Error, Equatable, Sendable {
    case unauthorized
    case http(status: Int)
    case api(message: String)
    case malformedResponse
    case zoneNotFound(domain: String)
}

/// A single DNS record as returned by the Cloudflare API. Distinct from `DNSRecordPayload`
/// (write-only, no `id`/`proxied`) — this is the read-side shape used to list and display
/// existing records.
public struct DNSRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let type: String
    public let name: String
    public let content: String
    public let ttl: Int
    public let proxied: Bool
    public init(id: String, type: String, name: String, content: String, ttl: Int, proxied: Bool) {
        self.id = id
        self.type = type
        self.name = name
        self.content = content
        self.ttl = ttl
        self.proxied = proxied
    }
}

/// Read-only Cloudflare API seam. The concrete `HTTPCloudflareClient` talks to the
/// v4 REST API; tests provide a fake. Token is passed per call (no Keychain coupling).
public protocol CloudflareReading: Sendable {
    /// Resolve a zone's id from its apex domain, or nil if the token can't see it.
    func resolveZoneID(domain: String, apiToken: String) async throws -> String?
    /// Fetch the security-relevant state for a zone.
    func zoneState(zoneID: String, apiToken: String) async throws -> CloudflareZoneState
    /// Full DNS record listing for a zone — distinct from `zoneState`'s narrow security-relevant
    /// subset (CAA/MX/SPF/DMARC only). Used by the Domain DNS management feature.
    func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord]
}

/// Injectable HTTP boundary — identical shape to `CloudflareAPITokenVerifier.Transport`.
public typealias CloudflareTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
