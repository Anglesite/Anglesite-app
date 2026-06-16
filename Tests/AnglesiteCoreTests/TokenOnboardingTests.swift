import Testing
import Foundation
@testable import AnglesiteCore

/// Tests the verify → persist → (maybe) proceed orchestration in isolation from any UI. Cancellation
/// is an injected predicate rather than a real race, so the "cancelled deploy must not fire" rule is
/// asserted deterministically — and, unlike a hosted app test, this runs under `swift test`.
@MainActor
struct TokenOnboardingTests {
    private struct StubVerifier: TokenVerifying {
        let result: Result<CloudflareAccount, TokenVerifyError>
        func verify(token: String, siteDirectory: URL) async -> Result<CloudflareAccount, TokenVerifyError> {
            result
        }
    }

    private let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private let account = CloudflareAccount(name: "Acme Co.", email: nil)

    @Test("A verified token that isn't cancelled yields .proceed and persists once")
    func proceedsWhenNotCancelled() async {
        let onboarding = TokenOnboarding(verifier: StubVerifier(result: .success(account)))
        var persistCount = 0
        var connected: CloudflareAccount?
        let outcome = await onboarding.run(
            token: "  tok  ",
            siteDirectory: tmp,
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
        let onboarding = TokenOnboarding(verifier: StubVerifier(result: .success(account)))
        var persistCount = 0
        let outcome = await onboarding.run(
            token: "tok",
            siteDirectory: tmp,
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { true }
        )
        #expect(outcome == .abort)
        // The token verified, so it's still persisted; only the deploy dispatch is skipped.
        #expect(persistCount == 1)
    }

    @Test("A failed verification yields .stay and never persists")
    func staysOnFailure() async {
        let onboarding = TokenOnboarding(verifier: StubVerifier(result: .failure(.invalidToken)))
        var persistCount = 0
        let outcome = await onboarding.run(
            token: "bad",
            siteDirectory: tmp,
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        #expect(outcome == .stay(message: TokenVerifyError.invalidToken.userMessage))
        #expect(persistCount == 0)
    }

    @Test("An empty token stays without verifying or persisting")
    func staysOnEmpty() async {
        let onboarding = TokenOnboarding(verifier: StubVerifier(result: .success(account)))
        var persistCount = 0
        let outcome = await onboarding.run(
            token: "   ",
            siteDirectory: tmp,
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
        let onboarding = TokenOnboarding(verifier: StubVerifier(result: .success(account)))
        let outcome = await onboarding.run(
            token: "tok",
            siteDirectory: tmp,
            persist: { _ in throw Boom() },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        if case .stay = outcome {} else { Issue.record("expected .stay, got \(outcome)") }
    }
}
