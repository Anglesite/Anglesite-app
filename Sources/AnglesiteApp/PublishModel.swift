import SwiftUI
import AnglesiteCore

/// SwiftUI-facing wrapper around `RepoBootstrap`. Drives one publish at a time, mirrors the
/// `DeployModel` shape (a `Phase`, an `isRunning` flag, a sheet-presentation flag). All decision
/// logic lives in `RepoBootstrap`; this only maps events to view state.
@MainActor
@Observable
final class PublishModel {
    enum Phase: Equatable {
        case idle
        case running(milestone: String)
        case needsAuth
        case published(RemoteRepo)
        case failed(reason: String)
    }

    private(set) var phase: Phase = .idle
    /// Remote read on window open; drives the toolbar label (Publish vs View on GitHub).
    private(set) var existingRemote: RemoteRepo?

    /// Bound to the progress/result sheet in `SiteWindow`.
    var sheetPresented: Bool = false
    /// Bound to `GitHubAuthSheetView` when the provider needs `gh auth login`.
    var authSheetPresented: Bool = false

    var isRunning: Bool { if case .running = phase { return true }; return false }

    private let bootstrap: RepoBootstrap
    private var inFlight: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(bootstrap: RepoBootstrap = .live()) { self.bootstrap = bootstrap }

    /// Cheap read of `origin` to decide the toolbar label. Safe to call on window open; a rapid
    /// re-open cancels the prior read so a late-completing one can't clobber a newer result.
    func refreshRemote(source: URL) {
        refreshTask?.cancel()
        refreshTask = Task { self.existingRemote = await bootstrap.remote(of: source) }
    }

    /// Toolbar action. No-op if a publish is already running.
    func publish(source: URL, repoName: String) {
        start(source: source, repoName: repoName)
    }

    /// Re-run publish after the user finishes `gh auth login` in the auth sheet.
    func authCompleted(source: URL, repoName: String) {
        authSheetPresented = false
        start(source: source, repoName: repoName)
    }

    func dismiss() { sheetPresented = false }

    /// Single entry point for kicking off a publish. The `guard` is the only concurrency gate —
    /// it prevents both a second toolbar tap and `authCompleted` from opening a second `consume`
    /// loop over the same window.
    private func start(source: URL, repoName: String) {
        guard !isRunning else { return }
        phase = .running(milestone: "Starting…")
        sheetPresented = true
        inFlight = Task { await self.consume(bootstrap.publish(source: source, repoName: repoName, isPrivate: true), source: source) }
    }

    private func consume(_ stream: AsyncStream<RepoBootstrap.Event>, source: URL) async {
        for await event in stream {
            switch event {
            case .progress(_, let message): phase = .running(milestone: message)
            case .needsAuth:
                phase = .needsAuth
                authSheetPresented = true
                sheetPresented = false
            case .published(let repo):
                phase = .published(repo)
                existingRemote = repo
            case .failed(let reason):
                phase = .failed(reason: reason)
            }
        }
        // If the task was cancelled without a terminal event, the stream finishes while phase is
        // still .running — reset so isRunning clears and the toolbar button re-enables.
        if case .running = phase { phase = .idle }
    }
}
