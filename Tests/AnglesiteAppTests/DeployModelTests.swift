import Testing
import Foundation
@testable import Anglesite
import AnglesiteCore

/// Hosted tests for `DeployModel`'s token-onboarding orchestration — the MainActor logic that lives
/// in the app target and so isn't reachable from `swift test`. The focus is the verify-then-persist
/// flow's cancellation handling: a Cancel (or task teardown) during the verify/success-flash
/// suspensions must not launch a deploy behind the user's back.
///
/// `wrangler whoami` is never run — a stub `TokenVerifying` returns the result synchronously, and a
/// trivial `DeployCommand` (resolving to `/usr/bin/true`) stands in for the real deploy so the
/// positive-control test doesn't spawn a build/wrangler.
@MainActor
struct DeployModelTests {

    /// A `CLOUDFLARE_API_TOKEN` in the environment short-circuits the prompt (the deploy runs
    /// immediately), so these prompt-flow tests only apply when it's absent.
    static let promptReachable = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"]?.isEmpty ?? true

    private struct StubVerifier: TokenVerifying {
        let result: Result<CloudflareAccount, TokenVerifyError>
        func verify(token: String, siteDirectory: URL) async -> Result<CloudflareAccount, TokenVerifyError> {
            result
        }
    }

    /// A `DeployCommand` whose steps all resolve to `/usr/bin/true` and whose preflight passes, so
    /// `deploy()` runs to completion without touching npm, wrangler, or the network.
    private func trivialCommand() -> DeployCommand {
        DeployCommand(
            resolveCommand: { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) },
            resolveBuildCommand: { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) },
            tokenSource: { "stub-token" },
            preflight: { _ in .passed(warnings: []) }
        )
    }

    private func uniqueKeychain() -> KeychainStore {
        KeychainStore(service: "dev.anglesite.tests." + UUID().uuidString)
    }

    private func makeModel(verifierResult: Result<CloudflareAccount, TokenVerifyError>) -> (DeployModel, KeychainStore) {
        let keychain = uniqueKeychain()
        let model = DeployModel(
            command: trivialCommand(),
            logCenter: LogCenter(),
            keychain: keychain,
            verifier: StubVerifier(result: verifierResult)
        )
        return (model, keychain)
    }

    /// Polls a MainActor condition up to `timeout`. Returns the final value.
    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    @Test("Cancelling during verification does not launch the parked deploy", .enabled(if: promptReachable))
    func cancelDuringVerifyDoesNotDeploy() async {
        let (model, keychain) = makeModel(verifierResult: .success(CloudflareAccount(name: "Acme Co.", email: nil)))
        defer { try? keychain.clearCloudflareToken() }

        model.deploy(siteID: "s", siteDirectory: tmp)
        #expect(model.tokenPromptPresented)

        // Kick off verification; it succeeds and parks in the 700ms `.connected` success flash.
        let task = Task { await model.verifyAndSaveToken("good-token") }
        let reachedFlash = await waitUntil {
            if case .connected = model.tokenVerification { return true }
            return false
        }
        #expect(reachedFlash, "verification should reach the .connected flash")

        // User cancels mid-flash.
        model.cancelTokenPrompt()
        await task.value

        // The deploy must not have fired: the streaming drawer never opened and we settled to idle.
        #expect(model.drawerPresented == false)
        #expect(model.tokenVerification == .idle)
        if case .running = model.phase {
            Issue.record("deploy was dispatched even though the user cancelled during verification")
        }
    }

    @Test("A verified token (no cancel) does launch the parked deploy", .enabled(if: promptReachable))
    func verifiedTokenDispatchesDeploy() async {
        let (model, keychain) = makeModel(verifierResult: .success(CloudflareAccount(name: "Acme Co.", email: nil)))
        defer { try? keychain.clearCloudflareToken() }

        model.deploy(siteID: "s", siteDirectory: tmp)
        #expect(model.tokenPromptPresented)

        await model.verifyAndSaveToken("good-token")

        // deploy() spawns its work on a Task; runDeploy opens the drawer at its start.
        let dispatched = await waitUntil { model.drawerPresented }
        #expect(dispatched, "a non-cancelled verified token should dispatch the parked deploy")
        #expect(model.tokenPromptPresented == false)
    }

    @Test("A failed verification keeps the sheet open and writes nothing to the Keychain", .enabled(if: promptReachable))
    func failedVerificationKeepsSheetOpen() async {
        let (model, keychain) = makeModel(verifierResult: .failure(.invalidToken))
        defer { try? keychain.clearCloudflareToken() }

        model.deploy(siteID: "s", siteDirectory: tmp)
        await model.verifyAndSaveToken("bad-token")

        #expect(model.tokenPromptPresented, "the sheet stays up so the user can correct the token")
        #expect(model.drawerPresented == false)
        if case .failed = model.tokenVerification {} else {
            Issue.record("expected .failed verification state, got \(model.tokenVerification)")
        }
        #expect((try? keychain.readCloudflareToken()) ?? nil == nil, "a rejected token must not be persisted")
    }
}
