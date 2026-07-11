import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for the native (no `gh` CLI) GitHub token verifier (#654). The HTTP step is injected, so
/// the classification logic is exercised without real network — mirrors
/// `CloudflareAPITokenVerifierTests`'s shape.
struct GitHubTokenVerifierTests {
    private static func transport(status: Int, json: String) -> GitHubAPITokenVerifier.Transport {
        { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), http)
        }
    }

    @Test("a valid token verifies and surfaces the login and name")
    func validToken() async {
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(
            status: 200, json: #"{"login":"octocat","name":"The Octocat"}"#))
        let result = await verifier.verify(token: "good")
        #expect(result == .success(GitHubAccount(login: "octocat", name: "The Octocat")))
    }

    @Test("a valid token with no display name still verifies")
    func validTokenNoDisplayName() async {
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(
            status: 200, json: #"{"login":"octocat","name":null}"#))
        let result = await verifier.verify(token: "good")
        #expect(result == .success(GitHubAccount(login: "octocat", name: nil)))
    }

    @Test("a 401 maps to .invalidToken")
    func unauthorized() async {
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(status: 401, json: #"{"message":"Bad credentials"}"#))
        let result = await verifier.verify(token: "bad")
        #expect(result == .failure(.invalidToken))
    }

    @Test("a 403 (insufficient scope) also maps to .invalidToken")
    func forbidden() async {
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(status: 403, json: #"{"message":"Forbidden"}"#))
        let result = await verifier.verify(token: "scoped-wrong")
        #expect(result == .failure(.invalidToken))
    }

    @Test("an empty token is rejected without a network call")
    func emptyToken() async {
        let verifier = GitHubAPITokenVerifier(transport: { _ in
            Issue.record("transport should not be called for an empty token")
            throw URLError(.badURL)
        })
        let result = await verifier.verify(token: "   ")
        #expect(result == .failure(.invalidToken))
    }

    @Test("a connection failure maps to .network")
    func networkFailure() async {
        let verifier = GitHubAPITokenVerifier(transport: { _ in throw URLError(.notConnectedToInternet) })
        let result = await verifier.verify(token: "any")
        #expect(result == .failure(.network))
    }

    @Test("a transient server error (5xx/429) maps to .unavailable, not .invalidToken")
    func transientServerError() async {
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(status: 503, json: #"{"message":"down"}"#))
        let result = await verifier.verify(token: "valid-but-github-is-down")
        guard case .failure(.unavailable) = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }

    @Test("an unparseable response maps to .unavailable, not a bad-token claim")
    func unparseableResponse() async {
        let verifier = GitHubAPITokenVerifier(transport: Self.transport(status: 200, json: "not json at all"))
        let result = await verifier.verify(token: "any")
        guard case .failure(.unavailable) = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }

    @Test("the request carries the bearer token and hits /user")
    func sendsBearerTokenToUserEndpoint() async {
        let captured = CapturedRequest()
        let verifier = GitHubAPITokenVerifier(transport: { request in
            await captured.record(request)
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"login":"octocat","name":null}"#.utf8), http)
        })
        _ = await verifier.verify(token: "secret-token")
        #expect(await captured.authHeader == "Bearer secret-token")
        #expect(await captured.path == "/user")
    }

    private actor CapturedRequest {
        private(set) var authHeader: String?
        private(set) var path: String?
        func record(_ request: URLRequest) {
            path = request.url?.path
            authHeader = request.value(forHTTPHeaderField: "Authorization")
        }
    }
}
