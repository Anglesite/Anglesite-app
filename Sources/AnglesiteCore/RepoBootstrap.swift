import Foundation

/// One-tap "Publish to GitHub". Owns the git-side preflight (detect remote, init, commit) and
/// delegates the create-remote-and-push step to a `RepoProvider`. See #68 / the design doc.
///
/// The git `origin` is the source of truth for published state — `remote(of:)` reads it; nothing
/// is persisted app-side. Every `git`/`gh` invocation goes through the injected `RepoCommandRunner`
/// (production: `ProcessSupervisor.shared.run`), so tests drive the flow without spawning anything.
public actor RepoBootstrap {
    public enum Step: Sendable, Equatable { case checkingRemote, initializing, committing, creatingRepo, pushing }

    public enum Event: Sendable, Equatable {
        case progress(step: Step, message: String)
        /// Provider has no credentials. The UI presents `GitHubAuthSheetView`, then retries `publish`.
        case needsAuth
        case published(RemoteRepo)
        case failed(reason: String)
    }

    private let provider: RepoProvider
    private let run: RepoCommandRunner
    private let env = URL(fileURLWithPath: "/usr/bin/env")

    public init(provider: RepoProvider, run: @escaping RepoCommandRunner) {
        self.provider = provider
        self.run = run
    }

    /// Reads `origin`; nil if there's no remote or `source` isn't a git repo.
    public func remote(of source: URL) async -> RemoteRepo? {
        guard let r = try? await run(env, ["git", "remote", "get-url", "origin"], source),
              r.exitCode == 0 else { return nil }
        return RemoteRepo.parse(remoteURL: r.stdout)
    }

    /// `git init` if needed, then commit if there are no commits or a dirty tree. Throws on git error.
    func ensureCommittable(source: URL, emit: @Sendable (Event) -> Void) async throws {
        let inside = try? await run(env, ["git", "rev-parse", "--is-inside-work-tree"], source)
        if inside?.exitCode != 0 {
            emit(.progress(step: .initializing, message: "Initializing git repository…"))
            let initR = try await run(env, ["git", "init"], source)
            guard initR.exitCode == 0 else { throw RepoBootstrapError(reason: "git init failed.\n\(initR.stderr)") }
        }

        let head = try? await run(env, ["git", "rev-parse", "HEAD"], source)
        let status = try await run(env, ["git", "status", "--porcelain"], source)
        let noCommits = head?.exitCode != 0
        let dirty = !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard noCommits || dirty else { return }

        // Refuse to stage likely-secret files. `git add -A` would otherwise sweep .env/.env.local
        // etc. into the repo; "private by default" doesn't protect a repo later made public or
        // visible org-wide, and secrets persist in history even after a force-push.
        let secrets = Self.dotenvFiles(inPorcelain: status.stdout)
        guard secrets.isEmpty else {
            throw RepoBootstrapError(reason: "Refusing to publish: \(secrets.joined(separator: ", ")) "
                + "would be committed. Add \(secrets.count == 1 ? "it" : "them") to .gitignore first.")
        }

        emit(.progress(step: .committing, message: "Committing your site…"))
        let add = try await run(env, ["git", "add", "-A"], source)
        guard add.exitCode == 0 else { throw RepoBootstrapError(reason: "git add failed.\n\(add.stderr)") }
        let commit = try await run(env, ["git", "commit", "-m", "Initial commit"], source)
        guard commit.exitCode == 0 else { throw RepoBootstrapError(reason: "git commit failed.\n\(commit.stderr)") }
    }

    /// Paths in `git status --porcelain` output whose filename is a dotenv secret (`.env` or
    /// `.env.<anything>`). Porcelain v1 lines are `XY <path>` (or `XY <old> -> <new>` for renames).
    static func dotenvFiles(inPorcelain porcelain: String) -> [String] {
        porcelain.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.count > 3 else { return nil }
            let entry = String(line.dropFirst(3))                       // strip the 2 status cols + space
            let path = entry.components(separatedBy: " -> ").last ?? entry   // rename → use the new path
            let name = (path as NSString).lastPathComponent
            return (name == ".env" || name.hasPrefix(".env.")) ? path : nil
        }
    }

    /// Detect → (auth) → ensure committable → create + push. Streams progress; settles to
    /// `.published` / `.needsAuth` / `.failed`. Idempotent: an already-published site yields
    /// `.published(existing)` with no side effects.
    public nonisolated func publish(source: URL, repoName: String, isPrivate: Bool) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                let emit: @Sendable (Event) -> Void = { continuation.yield($0) }

                emit(.progress(step: .checkingRemote, message: "Checking for an existing remote…"))
                if let existing = await self.remote(of: source) {
                    emit(.published(existing)); continuation.finish(); return
                }

                if await self.provider.isAuthenticated() == false {
                    emit(.needsAuth); continuation.finish(); return
                }

                do {
                    try await self.ensureCommittable(source: source, emit: emit)
                    emit(.progress(step: .creatingRepo, message: "Creating private repository on GitHub…"))
                    // Sanitize the display name: callers pass human names ("My Cool Site!"); GitHub
                    // repo names must be URL-safe slugs, so derive one via SiteSlug.
                    let slug = SiteSlug.derive(from: repoName)
                    let created = try await self.provider.createAndPush(name: slug, isPrivate: isPrivate, source: source)
                    emit(.progress(step: .pushing, message: "Pushed to \(created.url.absoluteString)"))
                    emit(.published(created))
                } catch let err as RepoBootstrapError {
                    emit(.failed(reason: err.reason))
                } catch {
                    emit(.failed(reason: "\(error)"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Production wiring: `git`/`gh` run through `ProcessSupervisor.shared.run`. The one-shot `run`
    /// path captures rather than streams, so the runner forwards captured stdout/stderr to
    /// `LogCenter` itself — per CLAUDE.md "logs are sacred", every spawned subprocess must reach
    /// the debug pane.
    public static func live(supervisor: ProcessSupervisor = .shared, logCenter: LogCenter = .shared) -> RepoBootstrap {
        let runner: RepoCommandRunner = { executable, args, cwd in
            let result = try await supervisor.run(executable: executable, arguments: args, currentDirectoryURL: cwd)
            let source = "repo-bootstrap"
            if !result.stdout.isEmpty { await logCenter.append(source: source, stream: .stdout, text: result.stdout) }
            if !result.stderr.isEmpty { await logCenter.append(source: source, stream: .stderr, text: result.stderr) }
            return result
        }
        return RepoBootstrap(provider: GHRepoProvider(run: runner), run: runner)
    }
}
