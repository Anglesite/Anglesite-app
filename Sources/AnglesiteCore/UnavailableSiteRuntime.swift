import Foundation

/// A validation-blocked `SiteRuntime` used after host Node retirement when no container runtime is
/// available. It makes accidental fallback obvious: opening a site produces a failed preview state
/// instead of silently spawning the old host subprocess runtime.
public actor UnavailableSiteRuntime: SiteRuntime {
    private let reason: String
    public let mcpClient: MCPClient
    private let stateMachine = SiteRuntimeStateMachine()

    public init(reason: String, mcpClient: MCPClient = MCPClient(supervisor: .shared)) {
        self.reason = reason
        self.mcpClient = mcpClient
    }

    public func start(siteID: String, siteDirectory: URL) async {
        stateMachine.setState(.failed(siteID: siteID, message: reason))
    }

    public func stop() async {
        await mcpClient.stop()
        stateMachine.setState(.idle)
    }

    public func observe() -> AsyncStream<SiteRuntimeState> {
        stateMachine.observe()
    }
}
