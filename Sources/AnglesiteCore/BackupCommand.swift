import Foundation

/// One-shot orchestrator for the deterministic backup path: `git add -A` →
/// `git commit -m "Backup <ISO timestamp>"` → `git push origin <branch>`.
///
/// Pairs with the LLM-routed `/anglesite:backup` skill, which retains the broader
/// surface (restore flow, descriptive commit summaries, branch-switching, gh-auth
/// recovery). The direct path is the optimistic case the chat panel wired through
/// Claude for no reason — Claude was just calling the same git tools every time.
///
/// Pre-flight checks before any working-tree mutation:
///   1. Branch: refuse on `main`. The plugin's backup skill is explicit that backup
///      pushes go to feature/draft branches; `main` is reserved for the deploy
///      pipeline. We surface a `.failed` with no override and let the user switch
///      branches (or use the chat-routed path, which can auto-switch to `draft`).
///   2. Remote: refuse if `origin` isn't configured. There's nowhere to push to.
///   3. Status: bail with `.noChanges` if the working tree is clean — no point
///      generating a no-op commit.
///
/// Then the action steps stream their output to `LogCenter` under
/// `backup:<siteID>`, so the drawer UI can show progress in real time.
public actor BackupCommand {
    public enum Result: Sendable, Equatable {
        case succeeded(commitSHA: String, branch: String, remote: String)
        case noChanges
        /// `exitCode` is `nil` for pre-spawn refusals (on `main`, no remote) and for
        /// spawn failures; otherwise it's the failing git subprocess's exit code.
        case failed(reason: String, exitCode: Int32?)
    }

    /// Runs a one-shot git command in the site directory, returns captured output.
    /// Used for introspection steps whose output we parse (`status`, `rev-parse`,
    /// `remote get-url`). Production uses `ProcessSupervisor.run(...)`; tests fake.
    public typealias GitRunner = @Sendable (_ siteDirectory: URL, _ arguments: [String]) async throws -> ProcessSupervisor.RunResult

    /// Runs a streaming git command (logs flow to `LogCenter` under `source`).
    /// Used for action steps whose output the drawer renders live (`add`, `commit`,
    /// `push`). Returns the git exit code; throws only on spawn failure.
    public typealias GitStreamer = @Sendable (_ siteDirectory: URL, _ arguments: [String], _ source: String) async throws -> Int32

    private let runner: GitRunner
    private let streamer: GitStreamer
    private let clock: @Sendable () -> Date

    public init(
        runner: @escaping GitRunner = BackupCommand.defaultRunner,
        streamer: @escaping GitStreamer = BackupCommand.defaultStreamer,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runner = runner
        self.streamer = streamer
        self.clock = clock
    }

    public func backup(siteID: String, siteDirectory: URL) async -> Result {
        let source = "backup:\(siteID)"

        // 1. Branch — refuse on main. Done first so a user who's on main isn't
        // surprised by a "no changes" message that would mask the real issue
        // when they later try to back up actual work.
        let branch: String
        do {
            let result = try await runner(siteDirectory, ["rev-parse", "--abbrev-ref", "HEAD"])
            guard result.exitCode == 0 else {
                return .failed(reason: "couldn't read current branch (`git rev-parse` exit \(result.exitCode))", exitCode: result.exitCode)
            }
            branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return .failed(reason: "couldn't run `git rev-parse`: \(error)", exitCode: nil)
        }
        if branch == "main" {
            return .failed(
                reason: "backup refuses to push to `main` — that's the deploy branch. Switch to `draft` (or another working branch) and try again.",
                exitCode: nil
            )
        }

        // 2. Remote — refuse when `origin` isn't configured. `git remote get-url`
        // exits non-zero with an empty stdout when the remote doesn't exist.
        let remote: String
        do {
            let result = try await runner(siteDirectory, ["remote", "get-url", "origin"])
            guard result.exitCode == 0 else {
                return .failed(
                    reason: "no `origin` remote configured — run `/anglesite:backup` in chat to set one up, or add one with `git remote add origin <url>`.",
                    exitCode: nil
                )
            }
            remote = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remote.isEmpty else {
                return .failed(reason: "the `origin` remote is configured but empty.", exitCode: nil)
            }
        } catch {
            return .failed(reason: "couldn't read `origin` remote: \(error)", exitCode: nil)
        }

        // 3. Status — bail early on a clean working tree.
        do {
            let result = try await runner(siteDirectory, ["status", "--porcelain"])
            guard result.exitCode == 0 else {
                return .failed(reason: "`git status` exited \(result.exitCode)", exitCode: result.exitCode)
            }
            if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .noChanges
            }
        } catch {
            return .failed(reason: "couldn't run `git status`: \(error)", exitCode: nil)
        }

        // 4. add → 5. commit → 6. read HEAD SHA → 7. push.
        // Each streamed action goes through the streamer so the drawer can render
        // live output (auth prompts on push are the obvious case).
        if let failure = await streamGit(["add", "-A"], in: siteDirectory, source: source, label: "git add") {
            return failure
        }
        let commitMessage = "Backup \(Self.iso8601Formatter.string(from: clock()))"
        if let failure = await streamGit(["commit", "-m", commitMessage], in: siteDirectory, source: source, label: "git commit") {
            return failure
        }
        let sha: String
        do {
            let result = try await runner(siteDirectory, ["rev-parse", "HEAD"])
            guard result.exitCode == 0 else {
                return .failed(reason: "couldn't read commit SHA (`git rev-parse HEAD` exit \(result.exitCode))", exitCode: result.exitCode)
            }
            sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return .failed(reason: "couldn't read commit SHA: \(error)", exitCode: nil)
        }
        if let failure = await streamGit(["push", "origin", branch], in: siteDirectory, source: source, label: "git push") {
            return failure
        }

        return .succeeded(commitSHA: sha, branch: branch, remote: remote)
    }

    // MARK: - Helpers

    /// Streams a single git action and maps the exit reason into a terminal `Result`.
    /// Returns `nil` on success — the caller can keep going.
    private func streamGit(
        _ arguments: [String],
        in siteDirectory: URL,
        source: String,
        label: String
    ) async -> Result? {
        do {
            let exit = try await streamer(siteDirectory, arguments, source)
            if exit == 0 { return nil }
            return .failed(reason: "`\(label)` failed (exit \(exit))", exitCode: exit)
        } catch {
            return .failed(reason: "couldn't spawn `\(label)`: \(error)", exitCode: nil)
        }
    }

    /// ISO-8601 timestamps in commit messages so they sort correctly under `git log` and
    /// stay locale-agnostic. `Backup 2026-06-10T14:13:20Z` — unambiguous, machine-friendly.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Default production seams

    /// Default `GitRunner`: shells out to `git` via `ProcessSupervisor.shared.run(...)`.
    /// Uses `/usr/bin/env` so the user's shell-resolved `git` is used (matches what they'd
    /// run in Terminal). Under the MAS sandbox this still spawns directly from the app, so
    /// the per-site security-scoped grant is inherited.
    public static let defaultRunner: GitRunner = { siteDirectory, arguments in
        try await ProcessSupervisor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: siteDirectory
        )
    }

    /// Default `GitStreamer`: launches `git` via `ProcessSupervisor.shared.launch(...)` so
    /// stdout/stderr flow into `LogCenter` line-by-line under `source`. Waits for exit and
    /// returns the code; `git push`'s auth-prompt back-and-forth is therefore visible in
    /// the drawer in real time.
    public static let defaultStreamer: GitStreamer = { siteDirectory, arguments, source in
        let handle = try await ProcessSupervisor.shared.launch(
            source: source,
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: siteDirectory
        )
        let reason = await ProcessSupervisor.shared.waitForExit(handle)
        switch reason {
        case .exited(let code):                return code
        case .terminated:                       return -1
        case .retriesExhausted(let lastCode):   return lastCode
        }
    }
}
