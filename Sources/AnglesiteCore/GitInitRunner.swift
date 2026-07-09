import Foundation

/// `git init`'s nonzero exit must not be discarded: it previously was in `SitesLauncherView`'s
/// production wiring (`_ = try await ProcessSupervisor...run(...)`), which meant a failing `git
/// init` never even reached `SiteScaffolder`'s `.warning` step — the new site silently kept a
/// `Source/` with no `.git`, and could never preview (#548).
public enum GitInitError: LocalizedError, Sendable, Equatable {
    case failed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .failed(let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "git init exited \(exitCode)." : "git init exited \(exitCode): \(detail)"
        }
    }
}

public enum GitInitRunner {
    /// Runs `git init` in `sourceDirectory` via `run`, throwing `GitInitError` (carrying stderr) on
    /// a nonzero exit instead of discarding the result.
    public static func run(
        in sourceDirectory: URL,
        using run: @Sendable (_ executable: URL, _ arguments: [String], _ cwd: URL?) async throws -> ProcessSupervisor.RunResult
    ) async throws {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let result = try await run(git, ["init"], sourceDirectory)
        guard result.exitCode == 0 else {
            throw GitInitError.failed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }
}
