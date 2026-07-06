import Foundation

// MARK: - Spawn data types
//
// The pure-`Codable` value types describing a spawn request and its result. Kept in their own
// file (separate from the `SupervisorBackend` protocol, which references the app-only `LogCenter`)
// so they stay dependency-light. `Codable` is no longer load-bearing now that the XPC helper is
// gone — the app spawns in-process via `InProcessBackend` — but it's harmless and these remain the
// single shared call shape.

/// One spawn request. `workingDirectory` is a plain path; the app holds the security-scoped
/// grant for that folder (per-`SiteWindow`) so the spawned child inherits access — nothing
/// bookmark-related crosses a process boundary.
public struct SpawnSpec: Sendable, Codable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: URL?
    /// When `true`, the spawned process gets a writable stdin pipe (MCP JSON-RPC framing needs this).
    public let stdinPipe: Bool
    /// Tag used by `LogCenter` when streaming stdout/stderr — e.g. `"container:<siteID>"`.
    public let logSource: String

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        stdinPipe: Bool = false,
        logSource: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.stdinPipe = stdinPipe
        self.logSource = logSource
    }
}

/// Result of a one-shot `runOneShot` call.
public struct ProcessResult: Sendable, Codable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Opaque token identifying a long-lived spawned process. The backend maps this to whatever
/// it tracks internally (a `Process` for InProcess, a pid + connection for XPC).
public struct SpawnedProcessHandle: Sendable, Codable, Equatable, Hashable {
    public let id: UUID
    public let pid: Int32

    public init(id: UUID = UUID(), pid: Int32) {
        self.id = id
        self.pid = pid
    }
}

public enum SupervisorBackendError: Error, Sendable {
    case spawnFailed(String)
    case unknownHandle
    case bookmarkResolutionFailed(String)
    case backendUnavailable(String)
}
