import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `BackupCommand` — the deterministic add/commit/push path that replaces
/// the chat-routed `/anglesite:backup` for one-click backups (#85).
///
/// Style matches `DeployCommandTests`: real `ProcessSupervisor` + `LogCenter` instances,
/// shell-fixture closures injected via the `runner`/`streamer` seams. The `clock` seam
/// makes commit-message timestamps deterministic.
struct BackupCommandTests {

    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private let fixedClock: @Sendable () -> Date = {
        Date(timeIntervalSince1970: 1_780_000_000)  // 2026-06-08 ~14:13 UTC
    }

    // MARK: Builder

    private func makeCommand(
        runner: @escaping BackupCommand.GitRunner,
        streamer: @escaping BackupCommand.GitStreamer = { _, _, _ in (0, "") }
    ) -> BackupCommand {
        BackupCommand(runner: runner, streamer: streamer, clock: fixedClock)
    }

    /// Fake runner that dispatches on the first git argument so each test can script multiple
    /// subcommands (`status`, `rev-parse`, `remote`) in one closure without nested switches.
    private func runner(
        _ table: [String: (stdout: String, exitCode: Int32)]
    ) -> BackupCommand.GitRunner {
        return { _, args in
            let key = args.first ?? ""
            guard let entry = table[key] else {
                return ProcessSupervisor.RunResult(stdout: "", stderr: "unmocked git \(args.joined(separator: " "))", exitCode: 1)
            }
            return ProcessSupervisor.RunResult(stdout: entry.stdout, stderr: "", exitCode: entry.exitCode)
        }
    }

    // MARK: Non-repo refusal

    @Test("Refuses outside a git repository with a clear, actionable message")
    func refusesOutsideGitRepo() async {
        // `git rev-parse --is-inside-work-tree` exits non-zero on a plain directory. The
        // command must stop here — before branch/remote/status — with a git-init remediation.
        let cmd = makeCommand(runner: { _, args in
            if args.contains("--is-inside-work-tree") {
                return .init(stdout: "", stderr: "fatal: not a git repository", exitCode: 128)
            }
            Issue.record("no git command should run after the work-tree check fails: \(args)")
            return .init(stdout: "", stderr: "unexpected", exitCode: 1)
        })
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.lowercased().contains("git repository"), "reason should name the missing repo: \(reason)")
        #expect(exit == nil, "non-repo refusal is pre-spawn — no exit code")
    }

    // MARK: noChanges

    @Test("Returns .noChanges when git status is empty")
    func returnsNoChangesWhenStatusEmpty() async {
        let cmd = makeCommand(runner: runner([
            "status": ("", 0),
            "rev-parse": ("draft\n", 0),
            "remote": ("git@github.com:owner/site.git\n", 0)
        ]))
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        #expect(result == .noChanges)
    }

    // MARK: Main-branch refusal

    @Test("Refuses when current branch is main")
    func refusesOnMain() async {
        let cmd = makeCommand(runner: runner([
            "status": (" M src/pages/index.astro\n", 0),
            "rev-parse": ("main\n", 0),
            "remote": ("git@github.com:owner/site.git\n", 0)
        ]))
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.contains("main"), "reason should explain the main-branch rule: \(reason)")
        #expect(exit == nil, "main-branch refusal is pre-spawn — no exit code")
    }

    // MARK: Missing-remote refusal

    @Test("Refuses when origin remote is not configured")
    func refusesWhenNoRemote() async {
        // git emits an empty stdout and non-zero exit when the remote doesn't exist.
        let cmd = makeCommand(runner: runner([
            "status": (" M src/pages/index.astro\n", 0),
            "rev-parse": ("draft\n", 0),
            "remote": ("", 2)
        ]))
        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .failed(let reason, _) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.lowercased().contains("remote"), "reason should mention the missing remote: \(reason)")
    }

    // MARK: Happy path

    @Test("Succeeds and returns commit SHA + branch + remote")
    func succeedsAndReturnsStructuredResult() async {
        // status/rev-parse/remote answer up-front; after commit, rev-parse HEAD returns the SHA.
        // The dispatcher returns whatever's at the keyed first arg, so HEAD is dispatched via "rev-parse"
        // — that's fine because we run branch-detection (rev-parse --abbrev-ref HEAD) before the
        // commit, and HEAD-SHA (rev-parse HEAD) after. The fake distinguishes them by args length.
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "status":   return .init(stdout: " M src/pages/index.astro\n", stderr: "", exitCode: 0)
            case "remote":   return .init(stdout: "git@github.com:owner/site.git\n", stderr: "", exitCode: 0)
            case "rev-parse":
                // `git rev-parse --abbrev-ref HEAD` for branch detection, `git rev-parse HEAD` for SHA.
                if args.contains("--abbrev-ref") {
                    return .init(stdout: "draft\n", stderr: "", exitCode: 0)
                }
                return .init(stdout: "abc1234deadbeef0000000000000000000000000\n", stderr: "", exitCode: 0)
            default:
                return .init(stdout: "", stderr: "unmocked", exitCode: 1)
            }
        }
        let cmd = makeCommand(runner: runner, streamer: { _, _, _ in (0, "") })

        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .succeeded(let sha, let branch, let remote) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(sha == "abc1234deadbeef0000000000000000000000000")
        #expect(branch == "draft")
        #expect(remote == "git@github.com:owner/site.git")
    }

    // MARK: Push failure

    @Test("Surfaces push failure with exit code and git's stderr")
    func surfacesPushFailureWithExitCode() async {
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "status":   return .init(stdout: " M src/pages/index.astro\n", stderr: "", exitCode: 0)
            case "remote":   return .init(stdout: "git@github.com:owner/site.git\n", stderr: "", exitCode: 0)
            case "rev-parse":
                if args.contains("--abbrev-ref") {
                    return .init(stdout: "draft\n", stderr: "", exitCode: 0)
                }
                return .init(stdout: "abc1234\n", stderr: "", exitCode: 0)
            default:
                return .init(stdout: "", stderr: "unmocked", exitCode: 1)
            }
        }
        let streamer: BackupCommand.GitStreamer = { _, args, _ in
            // Fail only on `git push` (with a realistic rejection on stderr); add/commit succeed.
            args.first == "push"
                ? (128, "! [rejected] draft -> draft (fetch first)\nerror: failed to push some refs")
                : (0, "")
        }
        let cmd = makeCommand(runner: runner, streamer: streamer)

        let result = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.lowercased().contains("push"), "reason should mention which step failed: \(reason)")
        #expect(reason.contains("rejected"), "reason should embed git's stderr so the user sees why: \(reason)")
        #expect(exit == 128)
    }

    // MARK: Commit message format

    @Test("Commit message uses ISO-8601 timestamp from injected clock")
    func commitMessageUsesISO8601Timestamp() async {
        // Capture the commit message by intercepting the streamer's args.
        let captured = LockedCapture()
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "status":   return .init(stdout: " M file\n", stderr: "", exitCode: 0)
            case "remote":   return .init(stdout: "origin-url\n", stderr: "", exitCode: 0)
            case "rev-parse":
                if args.contains("--abbrev-ref") {
                    return .init(stdout: "draft\n", stderr: "", exitCode: 0)
                }
                return .init(stdout: "abc\n", stderr: "", exitCode: 0)
            default:
                return .init(stdout: "", stderr: "unmocked", exitCode: 1)
            }
        }
        let streamer: BackupCommand.GitStreamer = { _, args, _ in
            if args.first == "commit" {
                captured.set(args)
            }
            return (0, "")
        }
        let cmd = makeCommand(runner: runner, streamer: streamer)

        _ = await cmd.backup(siteID: "site", siteDirectory: tmpDir)
        let committed = captured.get()
        // `git commit -m "Backup <ISO timestamp>"` — find the message after -m.
        guard let mIdx = committed.firstIndex(of: "-m"), mIdx + 1 < committed.count else {
            Issue.record("expected -m flag in commit args, got \(committed)")
            return
        }
        let message = committed[mIdx + 1]
        #expect(message.hasPrefix("Backup "), "message should start with 'Backup ': \(message)")
        // The fixed clock is 2026-06-08T~14:13Z; check the year/month land in the message.
        #expect(message.contains("2026"), "message should contain ISO year: \(message)")
    }

    // MARK: Source tagging

    @Test("Streams every action step under backup:<siteID>")
    func streamsActionsUnderBackupSiteIDSource() async {
        let sources = LockedSourceList()
        let runner: BackupCommand.GitRunner = { _, args in
            switch args.first {
            case "status":   return .init(stdout: " M file\n", stderr: "", exitCode: 0)
            case "remote":   return .init(stdout: "origin-url\n", stderr: "", exitCode: 0)
            case "rev-parse":
                if args.contains("--abbrev-ref") {
                    return .init(stdout: "draft\n", stderr: "", exitCode: 0)
                }
                return .init(stdout: "abc\n", stderr: "", exitCode: 0)
            default:
                return .init(stdout: "", stderr: "unmocked", exitCode: 1)
            }
        }
        let streamer: BackupCommand.GitStreamer = { _, _, source in
            sources.add(source)
            return (0, "")
        }
        let cmd = makeCommand(runner: runner, streamer: streamer)
        _ = await cmd.backup(siteID: "mysite", siteDirectory: tmpDir)

        let seen = sources.snapshot()
        #expect(seen.allSatisfy { $0 == "backup:mysite" }, "every streamed step must carry the site-specific source tag, got \(seen)")
        #expect(seen.count == 3, "expected add + commit + push, got \(seen.count): \(seen)")
    }
}

// MARK: - Sendable capture helpers
//
// Swift Testing closures are @Sendable so plain `var` doesn't work for cross-closure capture.
// These thin wrappers use NSLock for the small mutation the tests need.

private final class LockedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    func set(_ v: [String]) { lock.lock(); value = v; lock.unlock() }
    func get() -> [String] { lock.lock(); defer { lock.unlock() }; return value }
}

private final class LockedSourceList: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ v: String) { lock.lock(); values.append(v); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}
