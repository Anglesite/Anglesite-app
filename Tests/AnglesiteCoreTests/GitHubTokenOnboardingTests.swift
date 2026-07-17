import Testing
import Foundation
@testable import AnglesiteCore

/// Tests the verify → persist → (maybe) proceed orchestration in isolation from any UI, mirroring
/// `TokenOnboardingTests` (Cloudflare). Cancellation is an injected predicate rather than a real
/// race, so the "cancelled publish must not fire" rule is asserted deterministically — and, unlike
/// a hosted app test, this runs under `swift test`.
@MainActor
struct GitHubTokenOnboardingTests {
    private struct StubVerifier: GitHubTokenVerifying {
        let result: Result<GitHubAccount, GitHubTokenVerifyError>
        func verify(token: String) async -> Result<GitHubAccount, GitHubTokenVerifyError> {
            result
        }
    }

    private let account = GitHubAccount(login: "octocat", name: "The Octocat", avatarURL: nil)

    @Test("A verified token that isn't cancelled yields .proceed and persists once")
    func proceedsWhenNotCancelled() async {
        let onboarding = GitHubTokenOnboarding(verifier: StubVerifier(result: .success(account)))
        var persistCount = 0
        var connected: GitHubAccount?
        let outcome = await onboarding.run(
            token: "  tok  ",
            persist: { _ in persistCount += 1 },
            onConnected: { connected = $0 },
            delay: {},
            isCancelled: { false }
        )
        #expect(outcome == .proceed(account))
        #expect(persistCount == 1)
        #expect(connected == account)
    }

    @Test("Cancellation after a successful verify yields .abort (no proceed)")
    func abortsWhenCancelled() async {
        let onboarding = GitHubTokenOnboarding(verifier: StubVerifier(result: .success(account)))
        var persistCount = 0
        let outcome = await onboarding.run(
            token: "tok",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { true }
        )
        #expect(outcome == .abort)
        // The token verified, so it's still persisted; only the publish retry is skipped.
        #expect(persistCount == 1)
    }

    @Test("A failed verification yields .stay and never persists")
    func staysOnFailure() async {
        let onboarding = GitHubTokenOnboarding(verifier: StubVerifier(result: .failure(.invalidToken)))
        var persistCount = 0
        let outcome = await onboarding.run(
            token: "bad",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        #expect(outcome == .stay(message: GitHubTokenVerifyError.invalidToken.userMessage))
        #expect(persistCount == 0)
    }

    @Test("An empty token stays without verifying or persisting")
    func staysOnEmpty() async {
        let onboarding = GitHubTokenOnboarding(verifier: StubVerifier(result: .success(account)))
        var persistCount = 0
        let outcome = await onboarding.run(
            token: "   ",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        if case .stay = outcome {} else { Issue.record("expected .stay, got \(outcome)") }
        #expect(persistCount == 0)
    }

    @Test("A persist failure surfaces as .stay, not .proceed")
    func staysWhenPersistThrows() async {
        struct Boom: Error {}
        let onboarding = GitHubTokenOnboarding(verifier: StubVerifier(result: .success(account)))
        let outcome = await onboarding.run(
            token: "tok",
            persist: { _ in throw Boom() },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        if case .stay = outcome {} else { Issue.record("expected .stay, got \(outcome)") }
    }
}
