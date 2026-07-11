import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A GitHub account surfaced after a personal access token verifies — the identity Settings
/// displays instead of a bare "token stored" (mirrors Xcode's Accounts pane, which shows who
/// you're signed in as). `name` and `avatarURL` are best-effort niceties; `login` is always
/// present on a valid token.
public struct GitHubAccount: Sendable, Equatable {
    public let login: String
    public let name: String?
    public let avatarURL: URL?

    public init(login: String, name: String?, avatarURL: URL?) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// Why verifying a pasted GitHub token failed, with the user-facing copy Settings shows.
public enum GitHubTokenVerifyError: Error, Equatable, Sendable {
    /// The token was rejected by GitHub (bad/expired/revoked).
    case invalidToken
    /// We couldn't reach GitHub (DNS/connection failure).
    case network
    /// We couldn't check the token at all (rate limit, outage, unexpected response).
    case unavailable(String)

    public var userMessage: String {
        switch self {
        case .invalidToken:
            return "That token didn’t work. Create a fine-grained token with Contents: Read and write access at github.com/settings/tokens and paste the whole token."
        case .network:
            return "Couldn’t reach GitHub. Check your connection and try again."
        case .unavailable(let reason):
            return reason
        }
    }
}

/// Verifies a GitHub personal access token before it's persisted, so a bad token is caught at
/// the point of entry — and surfaces the connected identity for display, the same "verify then
/// persist" shape as `TokenVerifying` (Cloudflare).
public protocol GitHubTokenVerifying: Sendable {
    func verify(token: String) async -> Result<GitHubAccount, GitHubTokenVerifyError>
}

/// Verifies a GitHub PAT by calling `GET /user` on the GitHub REST API directly. The HTTP step
/// is injected (`Transport`) so the classification logic is unit-testable without real network —
/// same seam philosophy as `CloudflareAPITokenVerifier`.
public struct GitHubAPITokenVerifier: GitHubTokenVerifying {
    /// Performs one authenticated GET and returns its body + response. Throws on connection failure.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let baseURL: URL
    private let transport: Transport

    public init(
        baseURL: URL = URL(string: "https://api.github.com")!,
        transport: @escaping Transport = GitHubAPITokenVerifier.defaultTransport
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func verify(token: String) async -> Result<GitHubAccount, GitHubTokenVerifyError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("user"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            return .failure(.network)
        }

        // 401 is an unambiguous bad/expired/revoked token. `/user` needs no specific scope, so a
        // 403 is far more likely a rate limit than a genuinely invalid token — don't blame the
        // user's token for it. 429/5xx are transient outages, same reasoning.
        if http.statusCode == 401 {
            return .failure(.invalidToken)
        }
        if http.statusCode == 403 || http.statusCode == 429 || http.statusCode >= 500 {
            return .failure(.unavailable("GitHub is unavailable right now (HTTP \(http.statusCode)). Try again in a moment."))
        }
        guard (200..<300).contains(http.statusCode),
              let user = try? JSONDecoder().decode(UserResponse.self, from: data)
        else {
            return .failure(.unavailable("GitHub returned an unexpected response while checking the token."))
        }
        return .success(GitHubAccount(login: user.login, name: user.name, avatarURL: user.avatarURLString.flatMap(URL.init(string:))))
    }

    /// Production transport: a plain `URLSession` GET.
    public static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private struct UserResponse: Decodable {
        let login: String
        let name: String?
        let avatarURLString: String?

        enum CodingKeys: String, CodingKey {
            case login, name
            case avatarURLString = "avatar_url"
        }
    }
}
