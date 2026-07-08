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
        // `setState` dedups against the current value, so re-entering `.starting(siteID:)` for the
        // same site (Restart while already `.starting` — the "wedged boot" case this command exists
        // for) would otherwise be silently dropped: observers never see a change, so the progress
        // bar stays frozen on the superseded attempt. Force a transient `.idle` first only in that
        // specific case — `.ready`/`.failed`/`.idle` already differ from the new `.starting` value
        // and don't need it.
        if case .starting(let existingSiteID) = current, existingSiteID == siteID {
            setState(.idle)
        }
        setState(.starting(siteID: siteID))
        do {
            let token = mintToken()
            let session = try await control.start(
                siteID: siteID, gitRemote: gitRemote, gitRef: gitRef, token: token)
            // A superseding start()/stop() may have run its teardown() while this attempt was
            // suspended above — before `activeSiteID` was assigned, so that teardown() had nothing
            // of ours to stop. If we've been superseded, this attempt alone knows about the session
            // it just created, so it alone is responsible for tearing it down.
            guard gen == generation else { try? await control.stop(siteID: siteID); return }
            try await connect(mcpClient, session.mcpURL, token)
            guard gen == generation else { try? await control.stop(siteID: siteID); return }
            activeSiteID = siteID
            setState(.ready(siteID: siteID, url: session.previewURL))
        } catch {
            guard gen == generation else { return }
            setState(.failed(siteID: siteID, message: Self.friendlyMessage(for: error)))
        }
    }

    public func stop() async {
        generation += 1
        let gen = generation
        await teardown()
        // Actors are reentrant, so a start()/stop() issued while teardown() was suspended has
        // superseded this stop and owns the state now — emitting `.idle` here would clobber its
        // `.starting`/`.ready` (the rapid Stop → Restart race, PR #542 review): the UI would show
        // the boot spinner forever while the dev server is actually running.
        guard gen == generation else { return }
        setState(.idle)
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
