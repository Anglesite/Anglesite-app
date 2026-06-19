import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for the "clean working tree but commits ahead of origin" path in `BackupCommand`.
/// This covers the scenario where a previous backup committed but was cancelled before push,
/// leaving a local commit that the next backup should detect and push (#246).
@Suite(.serialized)
struct BackupCommandAheadOfOriginTests {

    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    /// Runner that passes all pre-flight checks (is-inside-work-tree, branch=draft, remote=url,
    /// status=empty) and then answers rev-list and rev-parse calls as specified.
    private func makePreflightPassingRunner(
        revListStdout: String,
        revListExitCode: Int32 = 0,
        headSHA: String = "abc1234deadbeef0000000000000000000000000"
    ) -> BackupCommand.GitRunner {
        { _, args in
            switch args.first {
            case "rev-parse":
                // is-inside-work-tree and abbrev-ref HEAD both key on "rev-parse"; is-inside-work-tree
                // only checks exitCode == 0, and abbrev-ref returns the branch name.
                if args.contains("--is-inside-work-tree") {
                    return ProcessSupervisor.RunResult(stdout: "true", stderr: "", exitCode: 0)
                }
                if args.contains("--abbrev-ref") {
                    return ProcessSupervisor.RunResult(stdout: "draft\n", stderr: "", exitCode: 0)
                }
                // rev-parse HEAD (for commit SHA after push)
                return ProcessSupervisor.RunResult(stdout: headSHA + "\n", stderr: "", exitCode: 0)
            case "remote":
                return ProcessSupervisor.RunResult(stdout: "git@github.com:owner/site.git\n", stderr: "", exitCode: 0)
            case "status":
                // Empty porcelain output = clean working tree
                return ProcessSupervisor.RunResult(stdout: "", stderr: "", exitCode: 0)
            case "rev-list":
                return ProcessSupervisor.RunResult(stdout: revListStdout, stderr: "", exitCode: revListExitCode)
            default:
                return ProcessSupervisor.RunResult(stdout: "", stderr: "unmocked: \(args.joined(separator: " "))", exitCode: 1)
            }
        }
    }

    @Test("Clean tree with commits ahead of origin pushes them and returns .succeeded")
    func cleanTreeAheadOfOriginPushes() async {
        let pushedArgs = LockedArgsCapture()
        let streamer: BackupCommand.GitStreamer = { _, args, _ in
            await pushedArgs.record(args)
            return (0, "")
        }
        let cmd = BackupCommand(
            runner: makePreflightPassingRunner(revListStdout: "1\n"),
            streamer: streamer
        )
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .succeeded(let sha, let branch, let remote) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(sha == "abc1234deadbeef0000000000000000000000000")
        #expect(branch == "draft")
        #expect(remote == "git@github.com:owner/site.git")

        // The streamer must have been called with push arguments
        let allArgs = await pushedArgs.all()
        let didPush = allArgs.contains { $0.first == "push" }
        #expect(didPush, "expected a git push to be streamed, got: \(allArgs)")
    }

    @Test("Clean tree with zero commits ahead returns .noChanges without pushing")
    func cleanTreeZeroAheadReturnsNoChanges() async {
        let pushedArgs = LockedArgsCapture()
        let streamer: BackupCommand.GitStreamer = { _, args, _ in
            await pushedArgs.record(args)
            return (0, "")
        }
        let cmd = BackupCommand(
            runner: makePreflightPassingRunner(revListStdout: "0\n"),
            streamer: streamer
        )
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        #expect(result == .noChanges)

        let allArgs = await pushedArgs.all()
        let didPush = allArgs.contains { $0.first == "push" }
        #expect(!didPush, "should NOT push when 0 commits ahead, but streamer was called with: \(allArgs)")
    }
}

private actor LockedArgsCapture {
    private var captured: [[String]] = []
    func record(_ args: [String]) { captured.append(args) }
    func all() -> [[String]] { captured }
}
