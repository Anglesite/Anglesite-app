import SwiftUI
import AnglesiteCore

/// SwiftUI-facing wrapper around `DeployCommand`. Drives one deploy at a time and exposes the
/// live log stream, the terminal `Phase`, and the two presentation flags the views consume.
///
/// Subscribes to `LogCenter` for the deploy's lifetime, filtering by source so the drawer only
/// shows wrangler / build output (not unrelated Astro or MCP traffic). Subscription is dropped
/// once the deploy resolves — the drawer keeps the captured `logLines` so the user can read and
/// copy them after dismissal becomes available.
@MainActor
@Observable
final class DeployModel {
    enum Phase: Equatable {
        case idle
        case running(siteID: String, since: Date)
        case succeeded(url: URL, duration: TimeInterval)
        case failed(reason: String, exitCode: Int32?)
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning])
    }

    private(set) var phase: Phase = .idle
    /// Captured deploy + build log lines for the current/most-recent run.
    private(set) var logLines: [LogCenter.LogLine] = []

    /// Bound to a custom slide-up drawer in `ContentView`. The view sets this back to false
    /// when the user clicks "Dismiss" (we never auto-close — users want to read the URL).
    var drawerPresented: Bool = false
    /// Bound to a `.sheet` in `ContentView` for the `.blocked` outcome. The sheet has no
    /// override button — per CLAUDE.md, the app cannot bypass plugin security hooks.
    var blockedPresented: Bool = false
    /// Bound to a `.sheet` in `ContentView` for the first-deploy "paste your Cloudflare token"
    /// flow. Set when `deploy(...)` is invoked without a token in either the env or the
    /// Keychain; cleared when the user saves a token (which then retries the deploy) or cancels.
    var tokenPromptPresented: Bool = false

    private let command: DeployCommand
    private let logCenter: LogCenter
    private let keychain: KeychainStore
    private var inFlight: Task<Void, Never>?
    /// Site to retry once the user pastes a token. `nil` outside the prompt flow.
    private var pendingDeploy: (siteID: String, siteDirectory: URL)?

    init(
        command: DeployCommand = DeployCommand(),
        logCenter: LogCenter = .shared,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.command = command
        self.logCenter = logCenter
        self.keychain = keychain
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Renders the captured log lines as plain text for the "Copy log" affordance on failure.
    var logText: String {
        logLines.map(\.text).joined(separator: "\n")
    }

    /// Kicks off a deploy. No-op if one is already running.
    ///
    /// First checks whether a Cloudflare token is available (env > Keychain). If neither has one,
    /// the token-prompt sheet is presented and the deploy is parked until the user saves a token
    /// via `saveTokenAndRetry(_:)` — at which point the parked site is dispatched without the
    /// user having to click Deploy again.
    func deploy(siteID: String, siteDirectory: URL) {
        guard !isRunning else { return }
        if !hasUsableToken() {
            pendingDeploy = (siteID, siteDirectory)
            tokenPromptPresented = true
            return
        }
        inFlight = Task { @MainActor [weak self] in
            await self?.runDeploy(siteID: siteID, siteDirectory: siteDirectory)
        }
    }

    /// Called by the token-prompt sheet's "Save" button. Persists the token to the Keychain and
    /// — if a deploy was parked on the prompt — kicks it off. Returns `nil` on success or an
    /// error message on failure (the sheet stays presented so the user can correct it).
    @discardableResult
    func saveTokenAndRetry(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Token is empty." }
        do {
            try keychain.writeCloudflareToken(trimmed)
        } catch {
            return "Couldn't save to Keychain: \(error)"
        }
        tokenPromptPresented = false
        if let pending = pendingDeploy {
            pendingDeploy = nil
            deploy(siteID: pending.siteID, siteDirectory: pending.siteDirectory)
        }
        return nil
    }

    func cancelTokenPrompt() {
        pendingDeploy = nil
        tokenPromptPresented = false
    }

    func dismissDrawer() {
        drawerPresented = false
    }

    func dismissBlocked() {
        blockedPresented = false
    }

    /// True if either the env var or the Keychain currently holds a non-empty Cloudflare token.
    /// Keychain errors are treated as "no token" — the user can recover by pasting fresh.
    private func hasUsableToken() -> Bool {
        if let env = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"], !env.isEmpty {
            return true
        }
        if let stored = (try? keychain.readCloudflareToken()) ?? nil, !stored.isEmpty {
            return true
        }
        return false
    }

    private func runDeploy(siteID: String, siteDirectory: URL) async {
        phase = .running(siteID: siteID, since: Date())
        logLines = []
        drawerPresented = true
        blockedPresented = false

        let sources = Set(["deploy:\(siteID)", "deploy:\(siteID):build"])

        // Subscribe BEFORE the deploy starts so we can't miss early build lines.
        let subscription = await logCenter.subscribe()
        let logTask = Task { @MainActor [weak self] in
            for await line in subscription.stream where sources.contains(line.source) {
                self?.logLines.append(line)
            }
        }

        let result = await command.deploy(siteID: siteID, siteDirectory: siteDirectory)

        subscription.cancel()
        _ = await logTask.value

        switch result {
        case .succeeded(let url, let duration):
            phase = .succeeded(url: url, duration: duration)
        case .failed(let reason, let exit):
            phase = .failed(reason: reason, exitCode: exit)
        case .blocked(let failures, let warnings):
            phase = .blocked(failures: failures, warnings: warnings)
            // For the blocked outcome the modal sheet carries the actionable info; the
            // streaming-log drawer would just be noise.
            drawerPresented = false
            blockedPresented = true
        }
    }
}
