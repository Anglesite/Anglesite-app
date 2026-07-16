import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors surfaced by the GitHub repo-creation client.
public enum GitHubRepoAPIError: Error, Equatable, Sendable {
    /// The transport itself failed (DNS/offline/TLS/timeout) — never reached GitHub, so this is
    /// distinct from `.api`, which means GitHub responded with a rejection.
    case network
    case unauthorized
    case nameAlreadyExists
    case http(status: Int)
    case api(message: String)
    case malformedResponse
}

/// Creates a GitHub repository via the REST API — no `gh` CLI, no Node. Part of #654's
/// sandbox-safe Publish-to-GitHub path: `gh repo create` shells out and MAS users generally
/// won't have `gh` installed at all.
///
/// `createRepo` only creates the remote repository — wiring `origin` and pushing into it is
/// `HTTPRepoProvider`'s job, using SwiftGit2's `addRemote`/`push` (#659).
public struct HTTPGitHubClient: Sendable {
    private static let base = "https://api.github.com"
    private let transport: GitHubAPITokenVerifier.Transport

    public init(transport: @escaping GitHubAPITokenVerifier.Transport = GitHubAPITokenVerifier.defaultTransport) {
        self.transport = transport
    }

    /// `POST /user/repos` — creates a repository owned by the authenticated user.
    public func createRepo(name: String, isPrivate: Bool, token: String) async throws -> RemoteRepo {
        guard let url = URL(string: Self.base + "/user/repos") else { throw GitHubRepoAPIError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CreateRepoBody(name: name, isPrivate: isPrivate))

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            throw GitHubRepoAPIError.network
        }

        if http.statusCode == 401 || http.statusCode == 403 { throw GitHubRepoAPIError.unauthorized }
        if http.statusCode == 422 {
            let envelope = try? JSONDecoder().decode(GitHubErrorResponse.self, from: data)
            // The name-conflict detail lives in `errors[].message`, not the top-level `message`
            // (which is a generic "Repository creation failed." for every 422 cause).
            if envelope?.errors?.contains(where: { $0.message.localizedCaseInsensitiveContains("already exists") }) == true {
                throw GitHubRepoAPIError.nameAlreadyExists
            }
            throw GitHubRepoAPIError.api(message: envelope?.message ?? "request failed")
        }
        guard (200..<300).contains(http.statusCode) else { throw GitHubRepoAPIError.http(status: http.statusCode) }
        guard let created = try? JSONDecoder().decode(CreatedRepoResponse.self, from: data),
              let browse = URL(string: created.htmlURL) else {
            throw GitHubRepoAPIError.malformedResponse
        }
        return RemoteRepo(url: browse, owner: created.owner.login, name: created.name)
    }

    private struct CreateRepoBody: Encodable {
        let name: String
        let isPrivate: Bool
        enum CodingKeys: String, CodingKey { case name, isPrivate = "private" }
    }

    private struct CreatedRepoResponse: Decodable {
        let name: String
        let htmlURL: String
        let owner: Owner
        enum CodingKeys: String, CodingKey { case name, htmlURL = "html_url", owner }
        struct Owner: Decodable { let login: String }
    }

    private struct GitHubErrorResponse: Decodable {
        let message: String
        let errors: [FieldError]?
        struct FieldError: Decodable { let message: String }
    }
}
