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

    private let command: DeployCommand
    private let logCenter: LogCenter
    private var inFlight: Task<Void, Never>?

    init(command: DeployCommand = DeployCommand(), logCenter: LogCenter = .shared) {
        self.command = command
        self.logCenter = logCenter
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
    func deploy(siteID: String, siteDirectory: URL) {
        guard !isRunning else { return }
        inFlight = Task { @MainActor [weak self] in
            await self?.runDeploy(siteID: siteID, siteDirectory: siteDirectory)
        }
    }

    func dismissDrawer() {
        drawerPresented = false
    }

    func dismissBlocked() {
        blockedPresented = false
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
