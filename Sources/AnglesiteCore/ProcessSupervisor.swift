import Foundation

/// Spawns and supervises subprocesses (Astro dev server, MCP server, Claude agent, ad-hoc Node smoke tests).
///
/// All subprocess spawning in the app goes through this actor. Direct `Process()` use from views or
/// other modules is not allowed — it would bypass log streaming and shutdown handling.
///
/// Phase 1 ships `run(...)` — a one-shot await-for-exit variant suitable for short-lived commands.
/// Phase 3 will add a streaming/restart-on-crash variant for long-running supervised processes.
public actor ProcessSupervisor {
    public init() {}

    public struct RunResult: Sendable, Equatable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32

        public init(stdout: String, stderr: String, exitCode: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
        }
    }

    public enum SupervisorError: Error, Sendable {
        case spawnFailed(underlying: Error)
    }

    /// Spawns `executable`, waits for it to exit, returns captured stdout/stderr/exitCode.
    ///
    /// Both pipes are drained concurrently so output larger than the pipe buffer (~64KB) does not deadlock.
    /// For long-running processes whose output must be streamed, use the Phase 3 streaming API (not yet implemented).
    public func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw SupervisorError.spawnFailed(underlying: error)
        }

        async let stdoutData = Self.readToEnd(stdoutPipe)
        async let stderrData = Self.readToEnd(stderrPipe)
        let (out, err) = await (stdoutData, stderrData)

        process.waitUntilExit()

        return RunResult(
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await Task.detached(priority: .userInitiated) {
            (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        }.value
    }
}
