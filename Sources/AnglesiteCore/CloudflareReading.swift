import Foundation

/// Errors surfaced by the Cloudflare read client.
public enum CloudflareError: Error, Equatable, Sendable {
    case unauthorized
    case http(status: Int)
    case api(message: String)
    case malformedResponse
    case zoneNotFound(domain: String)
}

/// Read-only Cloudflare API seam. The concrete `HTTPCloudflareClient` talks to the
/// v4 REST API; tests provide a fake. Token is passed per call (no Keychain coupling).
public protocol CloudflareReading: Sendable {
    /// Resolve a zone's id from its apex domain, or nil if the token can't see it.
    func resolveZoneID(domain: String, apiToken: String) async throws -> String?
    /// Fetch the security-relevant state for a zone.
    func zoneState(zoneID: String, apiToken: String) async throws -> CloudflareZoneState
}

/// Injectable HTTP boundary — identical shape to `CloudflareAPITokenVerifier.Transport`.
public typealias CloudflareTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
