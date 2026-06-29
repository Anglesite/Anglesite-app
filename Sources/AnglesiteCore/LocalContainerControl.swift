import Foundation

/// Host-reachable endpoints a started local container exposes. Both are 127.0.0.1 URLs on
/// OS-assigned ports, delivered by the host-side vsock→TCP proxy. Mirrors `SandboxSession`.
public struct LocalContainerSession: Sendable, Equatable {
    public let previewURL: URL
    public let mcpURL: URL
    public init(previewURL: URL, mcpURL: URL) {
        self.previewURL = previewURL
        self.mcpURL = mcpURL
    }
}

public enum LocalContainerError: Error, Equatable {
    case virtualizationUnavailable      // no entitlement / not Apple Silicon / macOS < 26
    case imageUnavailable(String)       // bundled OCI layout missing or failed to import
    case bootFailed(String)             // VM/container failed to boot
    case cloneFailed(String)            // git clone of Source/ into the guest failed
}

/// The captured output of a guest `exec` call. No `Containerization`/`Virtualization` types cross
/// this boundary — only `String` and `Int32`.
public struct ContainerExecResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Typed wrapper over "boot a container, hydrate it from a repo, start the guest processes, and
/// return host-reachable endpoints." `ContainerizationControl` (in AnglesiteContainer) is the
/// production conformer; `FakeLocalContainerControl` backs the tests. Mirrors `SandboxControlClient`.
/// No `Containerization`/`Virtualization` types cross this seam.
public protocol LocalContainerControl: Sendable {
    func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession
    func stop(siteID: String) async throws

    /// Run `argv` inside the named container's guest environment, streaming each output line to
    /// `onOutput` (tagged with the stream it came from — `.stdout`/`.stderr`) as it arrives, and
    /// returning the captured result when the process exits. No `Containerization`/`Virtualization`
    /// types cross this seam.
    ///
    /// `onOutput` is `@escaping`: the production conformer hands it to the guest process's `Writer`
    /// sinks, which can legitimately fire it *after* `exec` returns (e.g. a kill-triggered final
    /// line on cancellation). The signature is honest about that — callers must not assume the
    /// closure is dead once `exec` resolves.
    func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult
}
