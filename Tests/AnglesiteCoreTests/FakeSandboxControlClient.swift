import Foundation
@testable import AnglesiteCore

actor FakeSandboxControlClient: SandboxControlClient {
    var startResult: Result<SandboxSession, SandboxControlError>
    var statusResult: Result<SandboxStatus, SandboxControlError>
    private(set) var stopped: [String] = []
    private(set) var startedToken: SessionToken?

    init(
        startResult: Result<SandboxSession, SandboxControlError>,
        statusResult: Result<SandboxStatus, SandboxControlError> = .success(
            SandboxStatus(siteID: "site-1", previewReady: true, mcpReady: true)
        )
    ) {
        self.startResult = startResult
        self.statusResult = statusResult
    }

    func start(siteID: String, gitRemote: URL, gitRef: String, token: SessionToken) async throws -> SandboxSession {
        startedToken = token
        return try startResult.get()
    }

    func status(siteID: String) async throws -> SandboxStatus {
        try statusResult.get()
    }

    func stop(siteID: String) async throws { stopped.append(siteID) }
}

/// A `SandboxControlClient` whose `start` suspends until `release()` is called.
/// Use this to deterministically interleave a concurrent `stop()` or second `start()`
/// while the first `start()` is parked inside `control.start(...)`.
actor GatedFakeSandboxControlClient: SandboxControlClient {
    private let result: Result<SandboxSession, SandboxControlError>
    private(set) var stopped: [String] = []

    // Signals when `start` is parked (test waits on this before acting).
    private var parkedContinuation: CheckedContinuation<Void, Never>?
    // Gate: `start` resumes when this is fulfilled.
    private var gateContinuation: CheckedContinuation<Void, Never>?

    init(result: Result<SandboxSession, SandboxControlError>) {
        self.result = result
    }

    /// Suspend until `start` parks itself (i.e. the runtime is inside `control.start`).
    func waitUntilParked() async {
        await withCheckedContinuation { cont in
            parkedContinuation = cont
        }
    }

    /// Release the suspended `start` call so it returns its result.
    func release() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    func start(siteID: String, gitRemote: URL, gitRef: String, token: SessionToken) async throws -> SandboxSession {
        // Signal to the test that we are now parked.
        await withCheckedContinuation { cont in
            parkedContinuation?.resume()
            parkedContinuation = nil
            // Park here until the test calls release().
            gateContinuation = cont
        }
        return try result.get()
    }

    func status(siteID: String) async throws -> SandboxStatus {
        SandboxStatus(siteID: siteID, previewReady: true, mcpReady: true)
    }

    func stop(siteID: String) async throws { stopped.append(siteID) }
}
