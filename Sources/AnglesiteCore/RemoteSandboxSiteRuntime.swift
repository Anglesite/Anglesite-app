import Foundation

/// `SiteRuntime` over a Cloudflare Sandbox (iOS-only; see design 2026-06-23). Mirrors
/// `LocalSiteRuntime`'s state machine but drives a `SandboxControlClient` instead of a local
/// subprocess: mint a token, start the session, connect the MCP client to the returned MCP tunnel,
/// settle to `.ready`/`.failed`. Spawns nothing locally.
public actor RemoteSandboxSiteRuntime: SiteRuntime {
    private let gitRemote: URL
    private let gitRef: String
    private let control: any SandboxControlClient
    public let mcpClient: MCPClient
    private let mintToken: @Sendable () -> SessionToken
    private let connect: @Sendable (MCPClient, URL) async throws -> Void

    private var current: SiteRuntimeState = .idle
    private var observers: [UUID: AsyncStream<SiteRuntimeState>.Continuation] = [:]
    private var generation = 0
    private var activeSiteID: String?

    public init(
        gitRemote: URL,
        gitRef: String,
        control: any SandboxControlClient,
        mcpClient: MCPClient,
        mintToken: @escaping @Sendable () -> SessionToken = { SessionToken.mint() },
        // Default carries no bearer token. The in-container MCP sidecar bearer check + a
        // token-carrying connect closure are deferred to the iOS onboarding sub-plan (see
        // design 2026-06-23 §5 and the plan's Deferred sub-plans); this tokenless default
        // must NOT be wired into production.
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { c, u in try await c.connect(httpEndpoint: u) }
    ) {
        self.gitRemote = gitRemote
        self.gitRef = gitRef
        self.control = control
        self.mcpClient = mcpClient
        self.mintToken = mintToken
        self.connect = connect
    }

    public var state: SiteRuntimeState { current }

    public func observe() -> AsyncStream<SiteRuntimeState> {
        let (stream, continuation) = AsyncStream<SiteRuntimeState>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(current)
        return stream
    }

    /// `siteDirectory` is unused on the remote path (no local files on iOS); the git remote + ref
    /// come from `init`. Tears down any previous session, then settles to `.ready`/`.failed`.
    public func start(siteID: String, siteDirectory: URL) async {
        await teardown()
        generation += 1
        let gen = generation
        setState(.starting(siteID: siteID))
        do {
            let session = try await control.start(
                siteID: siteID, gitRemote: gitRemote, gitRef: gitRef, token: mintToken())
            guard gen == generation else { return }
            try await connect(mcpClient, session.mcpURL)
            guard gen == generation else { return }
            activeSiteID = siteID
            setState(.ready(siteID: siteID, url: session.previewURL))
        } catch {
            guard gen == generation else { return }
            setState(.failed(siteID: siteID, message: Self.friendlyMessage(for: error)))
        }
    }

    public func stop() async {
        generation += 1
        await teardown()
        setState(.idle)
    }

    // MARK: Internals

    private func teardown() async {
        await mcpClient.stop()
        if let id = activeSiteID {
            try? await control.stop(siteID: id)
            activeSiteID = nil
        }
    }

    private func setState(_ s: SiteRuntimeState) {
        guard s != current else { return }
        current = s
        for c in observers.values { c.yield(s) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    static func friendlyMessage(for error: Error) -> String {
        switch error {
        case SandboxControlError.notProvisioned: return "Connect a Cloudflare account to preview this site."
        case SandboxControlError.unauthorized:   return "Cloudflare rejected the session. Reconnect your account."
        case SandboxControlError.unreachable(let m): return "Couldn't reach Cloudflare: \(m)"
        case SandboxControlError.startFailed(let m): return "Couldn't start the remote preview: \(m)"
        default: return "Couldn't start the remote preview: \(error)"
        }
    }
}
