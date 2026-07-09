import XCTest
@testable import AnglesiteCore

/// Regression coverage for #548: production wiring in `SitesLauncherView` used to discard the
/// `RunResult` of `git init` entirely (`_ = try await ...run(...)`), so a nonzero exit code never
/// surfaced as an error or even a warning — the scaffolder's "non-fatal" git-init step silently
/// believed it had succeeded. `GitInitRunner` centralizes the exit-code check so it can't regress.
final class GitInitRunnerTests: XCTestCase {

    func testThrowsWithStderrOnNonzeroExit() async {
        let dir = URL(fileURLWithPath: "/tmp/some-site")
        do {
            try await GitInitRunner.run(in: dir) { _, _, _ in
                ProcessSupervisor.RunResult(stdout: "", stderr: "fatal: not a valid path", exitCode: 128)
            }
            XCTFail("expected GitInitError to be thrown")
        } catch let error as GitInitError {
            guard case .failed(let exitCode, let stderr) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(exitCode, 128)
            XCTAssertEqual(stderr, "fatal: not a valid path")
            XCTAssertEqual(error.errorDescription, "git init exited 128: fatal: not a valid path")
        } catch {
            XCTFail("expected GitInitError, got \(error)")
        }
    }

    func testSucceedsOnZeroExit() async throws {
        let dir = URL(fileURLWithPath: "/tmp/some-site")
        var capturedArgs: [String] = []
        var capturedCwd: URL?
        try await GitInitRunner.run(in: dir) { executable, args, cwd in
            capturedArgs = args
            capturedCwd = cwd
            XCTAssertEqual(executable.path, "/usr/bin/git")
            return ProcessSupervisor.RunResult(stdout: "Initialized empty Git repository", stderr: "", exitCode: 0)
        }
        XCTAssertEqual(capturedArgs, ["init"])
        XCTAssertEqual(capturedCwd, dir)
    }
}
