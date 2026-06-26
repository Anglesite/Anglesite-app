import Foundation

/// Verifies a Cloudflare API token by calling the Cloudflare REST API directly — no Node, no
/// wrangler. `GET /user/tokens/verify` confirms the token is valid and active; a best-effort
/// `GET /accounts` supplies the account-name nicety. The HTTP step is injected (`Transport`) so the
/// classification logic is unit-testable without real network — the same seam philosophy the old
/// wrangler-based verifier used for its process step. Conforms to `TokenVerifying`.
public struct CloudflareAPITokenVerifier: TokenVerifying {
    /// Performs one authenticated GET and returns its body + response. Throws on connection failure.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let baseURL: URL
    private let transport: Transport

    public init(
        baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
        transport: @escaping Transport = CloudflareAPITokenVerifier.defaultTransport
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func verify(token: String, siteDirectory: URL) async -> Result<CloudflareAccount, TokenVerifyError> {
        // `siteDirectory` is unused — verification is now a pure API call (kept for the protocol so
        // callers and the MAS sandbox grant path don't change).
        let data: Data
        do {
            (data, _) = try await get("user/tokens/verify", token: token)
        } catch {
            return .failure(.network)
        }
        guard let envelope = try? JSONDecoder().decode(VerifyEnvelope.self, from: data) else {
            return .failure(.unavailable("Cloudflare returned an unexpected response while checking the token."))
        }
        guard envelope.success, envelope.result?.status == "active" else {
            return .failure(.invalidToken)
        }
        // Best-effort account name — never fails verification.
        return .success(CloudflareAccount(name: await accountName(token: token), email: nil))
    }

    /// The first account's name, or `nil` if the lookup fails / returns nothing. A scoped token may
    /// lack `account:read`, so this is strictly a nicety; a `nil` name still means "verified".
    private func accountName(token: String) async -> String? {
        guard let (data, http) = try? await get("accounts", token: token),
              (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(AccountsEnvelope.self, from: data),
              let name = envelope.result.first?.name,
              !name.isEmpty
        else {
            return nil
        }
        return name
    }

    private func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await transport(request)
    }

    /// Production transport: a plain `URLSession` GET.
    public static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private struct VerifyEnvelope: Decodable {
        let success: Bool
        let result: TokenResult?
        struct TokenResult: Decodable { let status: String }
    }

    private struct AccountsEnvelope: Decodable {
        let result: [AccountInfo]
        struct AccountInfo: Decodable { let name: String }
    }
}
