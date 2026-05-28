import Foundation

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

/// The single seam between `ProcessSupervisor` and the underlying spawn mechanism.
///
/// - `InProcessBackend` (DevID): wraps `Process()` directly. No sandbox.
/// - `XPCBackend` (MAS): sends spawn requests to `AnglesiteHelper` over `NSXPCConnection`.
///
/// `ProcessSupervisor` picks one at init time and never branches on which is in use after that.
public protocol SupervisorBackend: Sendable {
    /// Synchronous one-shot. Spawns, drains stdout+stderr concurrently, waits for exit.
    func runOneShot(_ spec: SpawnSpec) async throws -> ProcessResult

    /// Long-lived spawn. Returns once the process is launched. Stdout/stderr lines flow into
    /// `LogCenter` tagged with `spec.logSource`.
    func launch(_ spec: SpawnSpec) async throws -> SpawnedProcessHandle

    /// SIGTERM → SIGKILL escalation after `timeout`. No-op if the handle is unknown or already exited.
    func terminate(_ handle: SpawnedProcessHandle, timeout: TimeInterval) async

    /// Stop every process the backend is tracking. Called on app quit / window close.
    func shutdownAll(timeout: TimeInterval) async

    /// Writes `bytes` to the spawned process's stdin. Throws if `spec.stdinPipe` was false.
    func writeStdin(_ handle: SpawnedProcessHandle, _ bytes: Data) async throws
}
