import Foundation

/// `SiteRuntime` over a Cloudflare Sandbox (iOS-only; see design 2026-06-23). Drives a
/// `SandboxControlClient`: mint a token, start the session, connect the MCP client to the returned MCP tunnel,
/// settle to `.ready`/`.failed`. Spawns nothing locally.
public actor RemoteSandboxSiteRuntime: SiteRuntime {
    private let gitRemote: URL
    private let gitRef: String
    private let control: any SandboxControlClient
    public let mcpClient: MCPClient
    private let mintToken: @Sendable () -> SessionToken
    private let connect: @Sendable (MCPClient, URL, SessionToken) async throws -> Void

    private let stateMachine = SiteRuntimeStateMachine()
    private var activeSiteID: String?

    public init(
        gitRemote: URL,
        gitRef: String,
        control: any SandboxControlClient,
        mcpClient: MCPClient,
        mintToken: @escaping @Sendable () -> SessionToken = { SessionToken.mint() },
        connect: @escaping @Sendable (MCPClient, URL, SessionToken) async throws -> Void = { c, u, token in
            try await c.connect(httpEndpoint: u, bearerToken: token)
        }
    ) {
        self.gitRemote = gitRemote
        self.gitRef = gitRef
        self.control = control
        self.mcpClient = mcpClient
        self.mintToken = mintToken
        self.connect = connect
    }

    public var state: SiteRuntimeState { stateMachine.state }

    public func observe() -> AsyncStream<SiteRuntimeState> {
        stateMachine.observe()
    }

    /// `siteDirectory` is unused on the remote path (no local files on iOS); the git remote + ref
    /// come from `init`. Tears down any previous session, then settles to `.ready`/`.failed`.
    public func start(siteID: String, siteDirectory: URL) async {
        await teardown()
        let gen = stateMachine.beginStarting(siteID: siteID)
        do {
            let token = mintToken()
            let session = try await control.start(
                siteID: siteID, gitRemote: gitRemote, gitRef: gitRef, token: token)
            // A superseding start()/stop() may have run its teardown() while this attempt was
            // suspended above — before `activeSiteID` was assigned, so that teardown() had nothing
            // of ours to stop. If we've been superseded, this attempt alone knows about the session
            // it just created, so it alone is responsible for tearing it down.
            guard stateMachine.isCurrent(gen) else { try? await control.stop(siteID: siteID); return }
            try await connect(mcpClient, session.mcpURL, token)
            guard stateMachine.isCurrent(gen) else { try? await control.stop(siteID: siteID); return }
            activeSiteID = siteID
            stateMachine.settle(gen: gen, to: .ready(siteID: siteID, url: session.previewURL))
        } catch {
            stateMachine.settle(gen: gen, to: .failed(siteID: siteID, message: Self.friendlyMessage(for: error)))
        }
    }

    public func stop() async {
        let gen = stateMachine.beginAttempt()
        await teardown()
        // Actors are reentrant, so a start()/stop() issued while teardown() was suspended has
        // superseded this stop and owns the state now — emitting `.idle` here would clobber its
        // `.starting`/`.ready` (the rapid Stop → Restart race, PR #542 review): the UI would show
        // the boot spinner forever while the dev server is actually running.
        stateMachine.settle(gen: gen, to: .idle)
    }

    // MARK: Internals

    private func teardown() async {
        // Clear `activeSiteID` before the suspensions, not after: a superseding start() can
        // complete a new boot (and re-assign `activeSiteID`) while this teardown is suspended in
        // `control.stop`, and nilling on resume would clobber the newer boot's bookkeeping —
        // orphaning its session. Clearing first also means overlapping teardowns stop the
        // session exactly once (PR #542 review).
        let sessionSiteID = activeSiteID
        activeSiteID = nil
        await mcpClient.stop()
        if let id = sessionSiteID {
            try? await control.stop(siteID: id)
        }
    }

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
