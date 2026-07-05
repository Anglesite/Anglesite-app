import Foundation

/// A Cloudflare account surfaced after a token verifies. Both fields are best-effort: `name` is
/// `nil` when the account lookup can't run or returns nothing (the token is still valid — the caller
/// falls back to a generic "verified" message), and `email` is `nil` for token auth that isn't
/// associated with a user email.
public struct CloudflareAccount: Sendable, Equatable {
    public let name: String?
    public let email: String?

    public init(name: String?, email: String?) {
        self.name = name
        self.email = email
    }
}

/// Why verifying a pasted Cloudflare token failed, with the user-facing copy the prompt shows.
public enum TokenVerifyError: Error, Equatable, Sendable {
    /// The token was rejected by Cloudflare (bad/expired/insufficient scope).
    case invalidToken
    /// We couldn't reach Cloudflare (DNS/connection failure).
    case network
    /// We couldn't check the token at all (unexpected response, etc.).
    case unavailable(String)

    public var userMessage: String {
        switch self {
        case .invalidToken:
            return "That token didn’t work. Use the “Create token” link (it pre-fills the “Anglesite” token) and copy the whole token."
        case .network:
            return "Couldn’t reach Cloudflare. Check your connection and try again."
        case .unavailable(let reason):
            return reason
        }
    }
}

/// Verifies a Cloudflare API token before it's persisted, so a bad token is caught at the point of
/// entry instead of failing later inside a deploy. The production conformer is
/// `CloudflareAPITokenVerifier` (a native REST call — no Node/wrangler).
public protocol TokenVerifying: Sendable {
    func verify(token: String, siteDirectory: URL) async -> Result<CloudflareAccount, TokenVerifyError>
}
