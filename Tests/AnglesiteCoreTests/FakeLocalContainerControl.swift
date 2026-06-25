import Foundation
@testable import AnglesiteCore

actor FakeLocalContainerControl: LocalContainerControl {
    var startResult: Result<LocalContainerSession, LocalContainerError>
    private(set) var stopped: [String] = []
    private(set) var startedRepos: [(siteID: String, repo: URL, ref: String)] = []

    init(startResult: Result<LocalContainerSession, LocalContainerError>) {
        self.startResult = startResult
    }

    func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession {
        startedRepos.append((siteID, sourceRepo, ref))
        return try startResult.get()
    }

    func stop(siteID: String) async throws { stopped.append(siteID) }
}

/// A `LocalContainerControl` whose `start` suspends until `release()` is called — for
/// deterministically interleaving a concurrent `stop()`/second `start()` while the first
/// `start()` is parked. Mirrors `GatedFakeSandboxControlClient`.
///
/// Note: the park/release rendezvous relies on Swift's cooperative executor not running the
/// spawned `start()` Task before `waitUntilParked()` installs its continuation. This matches the
/// pattern in `GatedFakeSandboxControlClient` and is sufficient for Swift Testing's executor.
actor GatedFakeLocalContainerControl: LocalContainerControl {
    private let result: Result<LocalContainerSession, LocalContainerError>
    private(set) var stopped: [String] = []
    private var parkedContinuation: CheckedContinuation<Void, Never>?
    private var gateContinuation: CheckedContinuation<Void, Never>?

    init(result: Result<LocalContainerSession, LocalContainerError>) { self.result = result }

    func waitUntilParked() async {
        await withCheckedContinuation { cont in parkedContinuation = cont }
    }
    func release() { gateContinuation?.resume(); gateContinuation = nil }

    func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession {
        await withCheckedContinuation { cont in
            parkedContinuation?.resume()
            parkedContinuation = nil
            gateContinuation = cont
        }
        return try result.get()
    }
    func stop(siteID: String) async throws { stopped.append(siteID) }
}
