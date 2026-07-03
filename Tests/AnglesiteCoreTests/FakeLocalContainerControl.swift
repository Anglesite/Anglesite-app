import Foundation
@testable import AnglesiteCore

actor FakeLocalContainerControl: LocalContainerControl {
    var startResult: Result<LocalContainerSession, LocalContainerError>
    private(set) var stopped: [String] = []
    private(set) var startedRepos: [(siteID: String, repo: URL, ref: String)] = []

    /// Lines replayed to `start`'s `onOutput` in order before it returns (or throws).
    var startStdoutLines: [String]

    /// Canned result returned by `exec`. Defaults to a successful empty run.
    var execResult: ContainerExecResult
    /// Lines replayed to `onOutput` in order before `exec` returns.
    var execStdoutLines: [String]
    /// All `exec` invocations recorded for assertion.
    private(set) var execCalls: [(siteID: String, argv: [String], env: [String: String], cwd: String)] = []

    init(
        startResult: Result<LocalContainerSession, LocalContainerError>,
        startStdoutLines: [String] = [],
        execResult: ContainerExecResult = ContainerExecResult(exitCode: 0, stdout: "", stderr: ""),
        execStdoutLines: [String] = []
    ) {
        self.startResult = startResult
        self.startStdoutLines = startStdoutLines
        self.execResult = execResult
        self.execStdoutLines = execStdoutLines
    }

    func start(
        siteID: String,
        sourceRepo: URL,
        ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession {
        startedRepos.append((siteID, sourceRepo, ref))
        for line in startStdoutLines { onOutput(line, .stdout) }
        return try startResult.get()
    }

    func stop(siteID: String) async throws { stopped.append(siteID) }

    func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult {
        execCalls.append((siteID: siteID, argv: argv, env: environment, cwd: workingDirectory))
        for line in execStdoutLines { onOutput(line, .stdout) }
        return execResult
    }
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

    func start(
        siteID: String,
        sourceRepo: URL,
        ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession {
        await withCheckedContinuation { cont in
            parkedContinuation?.resume()
            parkedContinuation = nil
            gateContinuation = cont
        }
        return try result.get()
    }
    func stop(siteID: String) async throws { stopped.append(siteID) }

    func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult {
        ContainerExecResult(exitCode: 0, stdout: "", stderr: "")
    }
}
