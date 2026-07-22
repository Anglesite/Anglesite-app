import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Cloudflare's registered OAuth client for the iOS onboarding flow (#889-#891). The client ID is
/// not a secret — PKCE public clients (`token_endpoint_auth_method: none`) have none — so it's
/// safe to commit. The redirect URI is the callback Worker from #891, reached via Apple Associated
/// Domains rather than a custom URL scheme: Cloudflare's OAuth-client registration form only
/// accepts `http(s)` redirect URIs.
public enum CloudflareOAuthConfiguration {
    public static let clientID = "e6705eb5f46254ecae0641b2e4da0ee2"
    public static let redirectURI = URL(string: "https://auth.anglesite.dwk.io/oauth-callback")!
    public static let discoveryURL = URL(string: "https://dash.cloudflare.com/.well-known/openid-configuration")!
}

/// The two endpoints a Cloudflare OAuth client needs, fetched from the OIDC discovery document
/// rather than hardcoded — standard OIDC practice, and survives Cloudflare relocating them.
struct OAuthDiscoveryDocument: Decodable, Sendable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL

    enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
    }
}

/// The token response from Cloudflare's token endpoint.
public struct OAuthToken: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

public enum CloudflareOAuthError: Error, Equatable, Sendable {
    /// Discovery document couldn't be fetched or decoded.
    case discoveryUnavailable(String)
    /// The callback's `state` didn't match the one this request minted — possible CSRF, never
    /// silently accepted.
    case stateMismatch
    /// The authorization server (or the user) denied the request, e.g. `error=access_denied`.
    case callbackDenied(String)
    /// The callback had a matching `state` but no `code`.
    case missingAuthorizationCode
    /// The token endpoint rejected the exchange or returned something undecodable.
    case tokenExchangeFailed(String)
}

/// One authorize attempt: the URL to present plus what's needed to complete it once a callback
/// URL comes back. `codeVerifier` never leaves this type except via `CloudflareOAuthClient.exchange`.
public struct CloudflareOAuthRequest: Sendable {
    public let authorizeURL: URL
    let state: String
    let codeVerifier: String
}

/// Cloudflare's self-managed OAuth (opened to all developers 2026-06-03): Authorization Code +
/// PKCE for public/native clients. This type only builds requests, parses callbacks, and exchanges
/// codes — presenting the actual browser sheet (`ASWebAuthenticationSession`) is the caller's job,
/// kept out of this type entirely so it stays fully unit-testable without `AuthenticationServices`
/// or any UI, the same separation `TokenOnboarding` keeps from SwiftUI. Mirrors
/// `CloudflareAPITokenVerifier`'s injected-`Transport` seam for the same reason.
public struct CloudflareOAuthClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let clientID: String
    private let redirectURI: URL
    private let scope: String
    private let discoveryURL: URL
    private let transport: Transport

    /// - scope: a Cloudflare OAuth scope name (== an API token permission-group name, e.g. the
    ///   dashboard's "User Details" Read). No default — the exact literal must come from the
    ///   registered client's available scopes (design doc §5's open item), not a guess baked in here.
    public init(
        clientID: String = CloudflareOAuthConfiguration.clientID,
        redirectURI: URL = CloudflareOAuthConfiguration.redirectURI,
        scope: String,
        discoveryURL: URL = CloudflareOAuthConfiguration.discoveryURL,
        transport: @escaping Transport = CloudflareOAuthClient.defaultTransport
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scope = scope
        self.discoveryURL = discoveryURL
        self.transport = transport
    }

    /// Fetches discovery, mints a PKCE verifier/challenge + CSRF state, and builds the authorize
    /// URL. The caller presents `request.authorizeURL` (e.g. via `ASWebAuthenticationSession`) and
    /// passes whatever callback URL comes back to `authorizationCode(from:matching:)`.
    public func makeAuthorizationRequest() async throws -> CloudflareOAuthRequest {
        let discovery = try await discover()
        let verifier = Self.makeCodeVerifier()
        let state = Self.makeState()
        guard var components = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw CloudflareOAuthError.discoveryUnavailable("malformed authorization_endpoint")
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: try Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            throw CloudflareOAuthError.discoveryUnavailable("couldn't build the authorize URL")
        }
        return CloudflareOAuthRequest(authorizeURL: url, state: state, codeVerifier: verifier)
    }

    /// Extracts and validates the authorization code from a completed browser session's callback
    /// URL against the `state` minted for `request`. Static and side-effect-free: this is pure URL
    /// parsing, not a network call.
    public static func authorizationCode(from callbackURL: URL, matching request: CloudflareOAuthRequest) throws -> String {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            throw CloudflareOAuthError.callbackDenied(value("error_description") ?? error)
        }
        guard let state = value("state"), state == request.state else {
            throw CloudflareOAuthError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty else {
            throw CloudflareOAuthError.missingAuthorizationCode
        }
        return code
    }

    /// Exchanges `code` (from `authorizationCode(from:matching:)`) + the matching request's PKCE
    /// verifier for an access token.
    public func exchange(code: String, for request: CloudflareOAuthRequest) async throws -> OAuthToken {
        let discovery = try await discover()
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: request.codeVerifier),
        ]
        var urlRequest = URLRequest(url: discovery.tokenEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = Data((form.percentEncodedQuery ?? "").utf8)

        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await transport(urlRequest)
        } catch {
            throw CloudflareOAuthError.tokenExchangeFailed(error.localizedDescription)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudflareOAuthError.tokenExchangeFailed("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        do {
            return try JSONDecoder().decode(OAuthToken.self, from: data)
        } catch {
            throw CloudflareOAuthError.tokenExchangeFailed("bad response: \(error)")
        }
    }

    private func discover() async throws -> OAuthDiscoveryDocument {
        var request = URLRequest(url: discoveryURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            throw CloudflareOAuthError.discoveryUnavailable(error.localizedDescription)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudflareOAuthError.discoveryUnavailable("HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(OAuthDiscoveryDocument.self, from: data)
        } catch {
            throw CloudflareOAuthError.discoveryUnavailable("bad response: \(error)")
        }
    }

    /// Production transport: a plain `URLSession` POST/GET, no auth of its own.
    public static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// 32 random bytes, base64url-encoded (no padding) — well within RFC 7636's 43-128 char range.
    /// `SystemRandomNumberGenerator` is cryptographically secure on every supported platform
    /// (arc4random_buf on Darwin, getrandom(2) on Linux) — same reasoning `SessionToken.mint()` uses.
    static func makeCodeVerifier() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return base64URLEncode(Data(bytes))
    }

    static func makeState() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return base64URLEncode(Data(bytes))
    }

    #if canImport(CryptoKit)
    static func codeChallenge(for verifier: String) throws -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }
    #else
    static func codeChallenge(for verifier: String) throws -> String {
        // OAuth login only ever happens from the iOS UI layer (`ASWebAuthenticationSession`),
        // which doesn't exist on Linux either — there's no path that reaches this on that platform
        // today. Throwing rather than hand-rolling SHA-256 keeps that honest instead of silently
        // producing a wrong challenge.
        throw CloudflareOAuthError.discoveryUnavailable("PKCE S256 challenge needs CryptoKit (Apple platforms only)")
    }
    #endif

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
