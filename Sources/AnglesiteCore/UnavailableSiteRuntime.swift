import Foundation

/// A validation-blocked `SiteRuntime` used after host Node retirement when no container runtime is
/// available. It makes accidental fallback obvious: opening a site produces a failed preview state
/// instead of silently spawning the old host subprocess runtime.
public actor UnavailableSiteRuntime: SiteRuntime {
    private let reason: String
    public let mcpClient: MCPClient
    private var current: SiteRuntimeState = .idle
    private var observers: [UUID: AsyncStream<SiteRuntimeState>.Continuation] = [:]

    public init(reason: String, mcpClient: MCPClient = MCPClient(supervisor: .shared)) {
        self.reason = reason
        self.mcpClient = mcpClient
    }

    public func start(siteID: String, siteDirectory: URL) async {
        setState(.failed(siteID: siteID, message: reason))
    }

    public func stop() async {
        await mcpClient.stop()
        setState(.idle)
    }

    public func observe() -> AsyncStream<SiteRuntimeState> {
        let (stream, continuation) = AsyncStream<SiteRuntimeState>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(current)
        return stream
    }

    private func setState(_ state: SiteRuntimeState) {
        guard state != current else { return }
        current = state
        for continuation in observers.values { continuation.yield(state) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
