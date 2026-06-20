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

    init(bootstrap: RepoBootstrap = .live()) { self.bootstrap = bootstrap }

    /// Cheap read of `origin` to decide the toolbar label. Safe to call on window open.
    func refreshRemote(source: URL) {
        Task { self.existingRemote = await bootstrap.remote(of: source) }
    }

    func publish(source: URL, repoName: String) {
        guard !isRunning else { return }
        phase = .running(milestone: "Starting…")
        sheetPresented = true
        inFlight?.cancel()
        inFlight = Task { await self.consume(bootstrap.publish(source: source, repoName: repoName, isPrivate: true), source: source) }
    }

    /// Re-run publish after the user finishes `gh auth login` in the auth sheet.
    func authCompleted(source: URL, repoName: String) {
        authSheetPresented = false
        publish(source: source, repoName: repoName)
    }

    func dismiss() { sheetPresented = false }

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
    }
}
