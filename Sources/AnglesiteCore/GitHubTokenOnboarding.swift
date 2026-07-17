import Foundation

/// Drives the "connect GitHub" token flow — verify the pasted token, persist it only if it's
/// good, surface the connected account, then decide whether to proceed — independent of any
/// SwiftUI. Mirrors `TokenOnboarding` (Cloudflare)'s verify → persist → flash → re-check-cancel →
/// proceed ordering, but against `GitHubTokenVerifying`/`GitHubAccount` and without a
/// `siteDirectory` parameter — GitHub token verification is a plain `GET /user` call with no
/// site-scoped check, unlike Cloudflare's wrangler-based verification. Kept as a separate type
/// rather than generalizing `TokenOnboarding<Account>`, since that would mean touching
/// `DeployModel` too — out of scope for #654.
///
/// `@MainActor` so it composes naturally with `PublishModel` (also MainActor) without `Sendable`
/// gymnastics on the closures.
@MainActor
public struct GitHubTokenOnboarding {
    public enum Outcome: Equatable {
        /// Token verified and persisted — the caller should retry the parked publish.
        case proceed(GitHubAccount)
        /// Verification (or persistence) failed — the caller keeps the prompt open with `message`.
        case stay(message: String)
        /// The user cancelled during the flow — the caller does nothing.
        case abort
    }

    private let verifier: GitHubTokenVerifying

    public init(verifier: GitHubTokenVerifying) {
        self.verifier = verifier
    }

    /// - persist: stores the token (e.g. Keychain write); only called on a successful verify, and a
    ///   throw turns the run into `.stay`.
    /// - onConnected: surfaces the connected account for the success flash, before `delay`.
    /// - delay: the success-flash pause — injectable so tests don't wait real time.
    /// - isCancelled: re-checked after verify + delay; `true` ⇒ `.abort` (no proceed).
    public func run(
        token: String,
        persist: (String) throws -> Void,
        onConnected: (GitHubAccount) -> Void,
        delay: () async -> Void,
        isCancelled: () -> Bool
    ) async -> Outcome {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .stay(message: "Paste your token first.") }

        switch await verifier.verify(token: trimmed) {
        case .failure(let error):
            return .stay(message: error.userMessage)
        case .success(let account):
            do {
                try persist(trimmed)
            } catch {
                return .stay(message: "Couldn’t save to Keychain: \(error)")
            }
            // Let the user see which account they connected, then re-check cancellation before
            // retrying the publish behind their back.
            onConnected(account)
            await delay()
            if isCancelled() { return .abort }
            return .proceed(account)
        }
    }
}
