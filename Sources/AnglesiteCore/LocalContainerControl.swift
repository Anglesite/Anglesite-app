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

/// Typed wrapper over "boot a container, hydrate it from a repo, start the guest processes, and
/// return host-reachable endpoints." `ContainerizationControl` (in AnglesiteContainer) is the
/// production conformer; `FakeLocalContainerControl` backs the tests. Mirrors `SandboxControlClient`.
/// No `Containerization`/`Virtualization` types cross this seam.
public protocol LocalContainerControl: Sendable {
    func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession
    func stop(siteID: String) async throws
}
