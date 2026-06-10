import SwiftUI
import AnglesiteCore

/// SwiftUI-facing wrapper around `BackupCommand`. Mirrors `DeployModel` — drives one backup
/// at a time, exposes the live log stream, the terminal `Phase`, and a single drawer flag.
@MainActor
@Observable
final class BackupModel {
    enum Phase: Equatable {
        case idle
        case running(siteID: String, since: Date)
        case succeeded(commitSHA: String, branch: String, remote: String, duration: TimeInterval)
        case noChanges
        case failed(reason: String, exitCode: Int32?)
    }

    private(set) var phase: Phase = .idle
    /// Captured backup log lines for the current/most-recent run.
    private(set) var logLines: [LogCenter.LogLine] = []

    /// Bound to a slide-up drawer in `SiteWindow`. The view sets this back to false when the
    /// user clicks "Dismiss" — we never auto-close on success because the commit SHA is
    /// worth letting the user see + copy, and on `.noChanges` the user explicitly asked.
    var drawerPresented: Bool = false

    private let command: BackupCommand
    private let logCenter: LogCenter
    private var inFlight: Task<Void, Never>?

    init(
        command: BackupCommand = BackupCommand(),
        logCenter: LogCenter = .shared
    ) {
        self.command = command
        self.logCenter = logCenter
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var logText: String {
        logLines.map(\.text).joined(separator: "\n")
    }

    /// Kicks off a backup. No-op if one is already running.
    func backup(siteID: String, siteDirectory: URL) {
        guard !isRunning else { return }
        inFlight = Task { @MainActor [weak self] in
            await self?.runBackup(siteID: siteID, siteDirectory: siteDirectory)
        }
    }

    func dismissDrawer() {
        drawerPresented = false
    }

    private func runBackup(siteID: String, siteDirectory: URL) async {
        let started = Date()
        phase = .running(siteID: siteID, since: started)
        logLines = []
        drawerPresented = true

        let source = "backup:\(siteID)"
        let subscription = await logCenter.subscribe()
        let logTask = Task { @MainActor [weak self] in
            for await line in subscription.stream where line.source == source {
                self?.logLines.append(line)
            }
        }

        let result = await command.backup(siteID: siteID, siteDirectory: siteDirectory)

        subscription.cancel()
        _ = await logTask.value

        let duration = Date().timeIntervalSince(started)
        switch result {
        case .succeeded(let sha, let branch, let remote):
            phase = .succeeded(commitSHA: sha, branch: branch, remote: remote, duration: duration)
        case .noChanges:
            phase = .noChanges
        case .failed(let reason, let exit):
            phase = .failed(reason: reason, exitCode: exit)
        }
    }
}
