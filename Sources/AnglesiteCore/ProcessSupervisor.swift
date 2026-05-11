import Foundation

/// Spawns and supervises long-running subprocesses (Astro dev server, MCP server, Claude agent).
///
/// All subprocess spawning in the app goes through this actor. Direct `Process()` use from views
/// or other modules is not allowed — it would bypass log streaming and shutdown handling.
///
/// Phase 3 will flesh this out. Phase 0 ships the type so other modules can compile against it.
public actor ProcessSupervisor {
    public init() {}

    public enum SupervisorError: Error {
        case notImplemented
    }

    public func spawn(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> Never {
        throw SupervisorError.notImplemented
    }
}
