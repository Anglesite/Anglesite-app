import Foundation

/// The two tunnel URLs a started remote session exposes: the preview (auth-proxy port) and the
/// in-container MCP server. Both are `*.trycloudflare.com` quick-tunnel URLs.
public struct SandboxSession: Sendable, Equatable {
    public let previewURL: URL
    public let mcpURL: URL
    public init(previewURL: URL, mcpURL: URL) {
        self.previewURL = previewURL
        self.mcpURL = mcpURL
    }
}

public struct SandboxStatus: Sendable, Equatable {
    public let siteID: String
    public let previewReady: Bool
    public let mcpReady: Bool

    public init(siteID: String, previewReady: Bool, mcpReady: Bool) {
        self.siteID = siteID
        self.previewReady = previewReady
        self.mcpReady = mcpReady
    }

    public var isReady: Bool { previewReady && mcpReady }
}

public enum SandboxControlError: Error, Equatable {
    case notProvisioned          // no Control Worker / token on file → route to onboarding
    case unauthorized            // token rejected by the Worker
    case unreachable(String)     // network / DNS
    case startFailed(String)     // Worker reported a boot/clone/hydrate failure
}

/// Typed wrapper over the user's Control Worker RPCs. The HTTPS impl (`HTTPSandboxControlClient`)
/// is one conformer; tests use `FakeSandboxControlClient`. No Cloudflare types leak across this seam.
public protocol SandboxControlClient: Sendable {
    /// Boot (or resume) the sandbox for `siteID`, clone `gitRemote` at `gitRef`, start the in-guest
    /// processes with `token` in their environment, and return the two tunnel URLs.
    func start(siteID: String, gitRemote: URL, gitRef: String, token: SessionToken) async throws -> SandboxSession
    /// Probe whether the in-guest preview proxy and MCP endpoint are reachable.
    func status(siteID: String) async throws -> SandboxStatus
    /// Stop the session (drop tunnels, let the sandbox sleep).
    func stop(siteID: String) async throws
}
