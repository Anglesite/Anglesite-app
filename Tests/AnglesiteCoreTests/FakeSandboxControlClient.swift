import Foundation
@testable import AnglesiteCore

actor FakeSandboxControlClient: SandboxControlClient {
    var startResult: Result<SandboxSession, SandboxControlError>
    private(set) var stopped: [String] = []
    private(set) var startedToken: SessionToken?

    init(startResult: Result<SandboxSession, SandboxControlError>) {
        self.startResult = startResult
    }

    func start(siteID: String, gitRemote: URL, gitRef: String, token: SessionToken) async throws -> SandboxSession {
        startedToken = token
        return try startResult.get()
    }

    func stop(siteID: String) async throws { stopped.append(siteID) }
}
