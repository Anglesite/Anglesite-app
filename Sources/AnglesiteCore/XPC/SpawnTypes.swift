import Foundation

// MARK: - Shared spawn data types
//
// These are the pure-`Codable` types that cross the XPC boundary. They live in
// `Sources/AnglesiteCore/XPC/` (alongside `AnglesiteHelperProtocol`) so the standalone
// `AnglesiteHelper` XPC service can compile them WITHOUT dragging in `LogCenter` or the
// rest of `AnglesiteCore`. The `SupervisorBackend` protocol + `RestartPolicy` /
// `ProcessExitReason` / `RespawnHandler` stay in `SupervisorBackend.swift` because they
// reference `LogCenter`, which is app-side only.

/// One spawn request, fully described and serializable. Crossing the XPC boundary requires
/// `Codable`; we use the same struct in-process too so DevID and MAS share one call shape.
public struct SpawnSpec: Sendable, Codable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: URL?
    /// Security-scoped bookmark for `workingDirectory`. MAS-only; the XPC helper resolves and
    /// `startAccessingSecurityScopedResource()`s before spawning. `nil` for DevID (no sandbox).
    public let workingDirectoryBookmark: Data?
    /// When `true`, the spawned process gets a writable stdin pipe (MCP JSON-RPC framing needs this).
    public let stdinPipe: Bool
    /// Tag used by `LogCenter` when streaming stdout/stderr — e.g. `"astro:dev:<siteID>"`.
    public let logSource: String

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        workingDirectoryBookmark: Data? = nil,
        stdinPipe: Bool = false,
        logSource: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.workingDirectoryBookmark = workingDirectoryBookmark
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
