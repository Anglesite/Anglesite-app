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

/// Hydration precondition: a `LocalContainerControl.start()` implementation hard-depends on
/// `sourceRepo` being a real git repo (it clones it into the guest). Kept as a plain, always-CI-
/// tested `AnglesiteCore` check rather than living inline in `ContainerizationControl` (whose test
/// target is excluded from CI's `swift test` unless `ANGLESITE_CONTAINER_TESTS=1`) — see #548,
/// where a `Source/` without `.git` (a failed scaffold git-init, or a pre-existing site) died
/// inside the guest with a raw `git clone ... exited 128` and no indication why.
public enum SourceRepoPrecondition {
    public static func requireGitRepo(at sourceRepo: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: sourceRepo.appendingPathComponent(".git").path) else {
            throw LocalContainerError.cloneFailed(
                "this site has no git repository — recreate it, or run `git init` in its Source folder")
        }
    }
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
    /// Boots the container and starts its guest processes (repo clone, `npm install` + `astro dev`,
    /// the MCP sidecar, the vsock bridge). `onOutput` receives every guest process's stdout/stderr
    /// line as it arrives — each line is prefixed with the emitting process's label (e.g. `[astro]`)
    /// so a single log source can distinguish them. Guest boot has historically been the least
    /// observable part of this stack (see #69): without this, a slow/hung `npm install` or a
    /// network/DNS failure inside the guest is invisible until `waitUntilServing`'s timeout fires
    /// with no diagnostic trail.
    ///
    /// `onOutput` is `@escaping`: the production conformer hands it to guest processes' `Writer`
    /// sinks, which can legitimately fire it after `start` returns (these processes are detached,
    /// not awaited) — up until `stop(siteID:)` tears the container down.
    func start(
        siteID: String,
        sourceRepo: URL,
        ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession
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
