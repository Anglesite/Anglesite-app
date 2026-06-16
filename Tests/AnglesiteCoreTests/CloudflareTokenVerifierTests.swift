import Testing
import Foundation
@testable import AnglesiteCore

/// Unit tests for the pure pieces of `WranglerTokenVerifier`: the `wrangler whoami` stdout parser,
/// the exit/output → error classification, the user-facing error copy, and the verify orchestration
/// (driven by an injected runner so no Node is spawned).
struct CloudflareTokenVerifierTests {

    // MARK: whoami parsing

    /// A representative `wrangler whoami` success with the account table and an email line.
    private static let whoamiWithEmail = """
     ⛅️ wrangler 4.20.0
    ───────────────────
    Getting User settings...
    👋 You are logged in with an API Token, associated with the email jane@example.com.
    ┌──────────────────────────┬──────────────────────────────────┐
    │ Account Name             │ Account ID                       │
    ├──────────────────────────┼──────────────────────────────────┤
    │ Acme Co.                 │ 0123456789abcdef0123456789abcdef │
    └──────────────────────────┴──────────────────────────────────┘
    🔓 Token Permissions: ...
    """

    /// A token-auth `wrangler whoami` with no email associated.
    private static let whoamiNoEmail = """
     ⛅️ wrangler 4.20.0
    ───────────────────
    Getting User settings...
    👋 You are logged in with an API Token.
    ┌─────────────────┬──────────────────────────────────┐
    │ Account Name    │ Account ID                       │
    ├─────────────────┼──────────────────────────────────┤
    │ Jane's Stuff    │ abcdef0123456789abcdef0123456789 │
    └─────────────────┴──────────────────────────────────┘
    """

    @Test("Parses the account name and email from a standard whoami table")
    func parsesNameAndEmail() {
        let account = WranglerTokenVerifier.parseWhoami(Self.whoamiWithEmail)
        #expect(account?.name == "Acme Co.")
        #expect(account?.email == "jane@example.com")
    }

    @Test("Parses the account name when no email is associated with the token")
    func parsesNameWithoutEmail() {
        let account = WranglerTokenVerifier.parseWhoami(Self.whoamiNoEmail)
        #expect(account?.name == "Jane's Stuff")
        #expect(account?.email == nil)
    }

    @Test("Returns nil when the output has no recognizable account table")
    func unparsableReturnsNil() {
        #expect(WranglerTokenVerifier.parseWhoami("total gibberish\nno table here") == nil)
    }

    // MARK: failure classification

    @Test("Classifies an auth failure as invalidToken")
    func classifiesAuthFailure() {
        let err = WranglerTokenVerifier.classifyFailure(
            stdout: "",
            stderr: "Authentication error [code: 10000]\nUnable to authenticate request"
        )
        #expect(err == .invalidToken)
    }

    @Test("Classifies a DNS/connection failure as network")
    func classifiesNetworkFailure() {
        let err = WranglerTokenVerifier.classifyFailure(
            stdout: "",
            stderr: "request to https://api.cloudflare.com failed, reason: getaddrinfo ENOTFOUND api.cloudflare.com"
        )
        #expect(err == .network)
    }

    @Test("An error merely mentioning 'network' is not misclassified as a connectivity failure")
    func ambiguousNetworkWordIsNotNetworkFailure() {
        // The bare word "network" appears in auth/config errors that aren't connectivity failures;
        // those must fall through to the safer .invalidToken default, not show "check your connection".
        let err = WranglerTokenVerifier.classifyFailure(
            stdout: "",
            stderr: "Authentication error [code: 10000]: your Workers network configuration is invalid"
        )
        #expect(err == .invalidToken)
    }

    // MARK: user-facing copy

    @Test("Invalid-token error names the Edit Cloudflare Workers template")
    func invalidTokenCopyNamesTemplate() {
        #expect(TokenVerifyError.invalidToken.userMessage.contains("Edit Cloudflare Workers"))
    }

    @Test("Network error tells the user to check their connection")
    func networkCopyMentionsConnection() {
        #expect(TokenVerifyError.network.userMessage.localizedCaseInsensitiveContains("connection"))
    }

    // MARK: verify orchestration (injected runner — no Node spawned)

    private let siteDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    @Test("A zero-exit whoami yields the parsed account")
    func verifySuccessReturnsAccount() async {
        let verifier = WranglerTokenVerifier { _, _ in
            ProcessSupervisor.RunResult(stdout: Self.whoamiWithEmail, stderr: "", exitCode: 0)
        }
        let result = await verifier.verify(token: "tok", siteDirectory: siteDir)
        #expect(result == .success(CloudflareAccount(name: "Acme Co.", email: "jane@example.com")))
    }

    @Test("A zero-exit but unparsable whoami still succeeds, with no account name")
    func verifySuccessFallsBackWhenUnparsable() async {
        let verifier = WranglerTokenVerifier { _, _ in
            ProcessSupervisor.RunResult(stdout: "logged in, somehow", stderr: "", exitCode: 0)
        }
        let result = await verifier.verify(token: "tok", siteDirectory: siteDir)
        #expect(result == .success(CloudflareAccount(name: nil, email: nil)))
    }

    @Test("A non-zero exit with an auth error fails as invalidToken")
    func verifyAuthFailure() async {
        let verifier = WranglerTokenVerifier { _, _ in
            ProcessSupervisor.RunResult(stdout: "", stderr: "Unable to authenticate request", exitCode: 1)
        }
        let result = await verifier.verify(token: "bad", siteDirectory: siteDir)
        #expect(result == .failure(.invalidToken))
    }

    @Test("A thrown runner error surfaces as an unavailable failure")
    func verifySpawnFailure() async {
        struct Boom: Error {}
        let verifier = WranglerTokenVerifier { _, _ in throw Boom() }
        let result = await verifier.verify(token: "tok", siteDirectory: siteDir)
        guard case .failure(.unavailable) = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }
}
