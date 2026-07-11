import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A GitHub account surfaced after a token verifies. `name` is best-effort (a user can have no
/// display name set), `login` is always present for a token that verified successfully.
public struct GitHubAccount: Sendable, Equatable {
    public let login: String
    public let name: String?

    public init(login: String, name: String?) {
        self.login = login
        self.name = name
    }
}

/// Why verifying a pasted GitHub token failed, with the user-facing copy a prompt would show.
/// Shaped like `TokenVerifyError` (Cloudflare's sibling) but GitHub-specific — kept as its own
/// type rather than generalizing `TokenVerifyError`, since the copy differs and there is exactly
/// one other conformer today.
public enum GitHubTokenVerifyError: Error, Equatable, Sendable {
    /// The token was rejected by GitHub (bad/expired/insufficient scope).
    case invalidToken
    /// We couldn't reach GitHub (DNS/connection failure).
    case network
    /// We couldn't check the token at all (unexpected response, etc.).
    case unavailable(String)

    public var userMessage: String {
        switch self {
        case .invalidToken:
            return "That token didn’t work. Create a token at github.com/settings/tokens with " +
                "“repo” scope and paste the whole thing."
        case .network:
            return "Couldn’t reach GitHub. Check your connection and try again."
        case .unavailable(let reason):
            return reason
        }
    }
}

/// Verifies a GitHub personal access token before it's persisted, so a bad token is caught at the
/// point of entry instead of failing later inside a publish. Mirrors `CloudflareAPITokenVerifier`'s
/// shape: a plain REST call (`GET /user`) with an injectable transport for testability.
public struct GitHubAPITokenVerifier: Sendable {
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
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.invalidToken) }

        var request = URLRequest(url: baseURL.appendingPathComponent("user"))
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            return .failure(.network)
        }

        if http.statusCode == 401 || http.statusCode == 403 { return .failure(.invalidToken) }
        if http.statusCode == 429 || http.statusCode >= 500 {
            return .failure(.unavailable("GitHub is unavailable right now (HTTP \(http.statusCode)). Try again in a moment."))
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.unavailable("GitHub returned an unexpected response (HTTP \(http.statusCode))."))
        }
        guard let user = try? JSONDecoder().decode(GitHubUserResponse.self, from: data), !user.login.isEmpty else {
            return .failure(.unavailable("GitHub returned an unexpected response while checking the token."))
        }
        return .success(GitHubAccount(login: user.login, name: user.name))
    }

    /// Production transport: a plain `URLSession` GET.
    public static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

struct GitHubUserResponse: Decodable, Sendable {
    let login: String
    let name: String?
}
