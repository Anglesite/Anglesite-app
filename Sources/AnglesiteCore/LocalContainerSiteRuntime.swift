import Foundation

/// `SiteRuntime` over a local Apple-Containerization VM (macOS 26+/Apple Silicon; see design
/// 2026-06-25). Mirrors `LocalSiteRuntime`'s state machine but drives a `LocalContainerControl`
/// instead of a local subprocess: boot the container, hydrate it from the site's `Source/` git
/// repo, connect the MCP client to the returned MCP endpoint, settle to `.ready`/`.failed`.
/// Spawns nothing in-process.
public actor LocalContainerSiteRuntime: SiteRuntime {
    private let ref: String
    private let control: any LocalContainerControl
    public let mcpClient: MCPClient
    private let knowledgeIndex: SiteKnowledgeIndex?
    private let connect: @Sendable (MCPClient, URL) async throws -> Void

    private var current: SiteRuntimeState = .idle
    private var observers: [UUID: AsyncStream<SiteRuntimeState>.Continuation] = [:]
    private var generation = 0
    private var activeSiteID: String?
    private var loadedKnowledgeSiteID: String?

    public init(
        ref: String,
        control: any LocalContainerControl,
        mcpClient: MCPClient,
        knowledgeIndex: SiteKnowledgeIndex? = nil,
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { c, u in try await c.connect(httpEndpoint: u) }
    ) {
        self.ref = ref
        self.control = control
        self.mcpClient = mcpClient
        self.knowledgeIndex = knowledgeIndex
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

    /// `siteDirectory` is the package's `Source/` directory; it becomes the `file://` repo the
    /// container clones (git is the source of truth, #72). The configured `ref` selects the commit.
    public func start(siteID: String, siteDirectory: URL) async {
        await teardown()
        generation += 1
        let gen = generation
        setState(.starting(siteID: siteID))
        do {
            let session = try await control.start(siteID: siteID, sourceRepo: siteDirectory, ref: ref)
            guard gen == generation else { return }
            try await connect(mcpClient, session.mcpURL)
            guard gen == generation else { return }
            await knowledgeIndex?.rebuild(siteID: siteID, projectRoot: siteDirectory)
            guard gen == generation else {
                await knowledgeIndex?.unload(siteID: siteID)
                return
            }
            loadedKnowledgeSiteID = siteID
            activeSiteID = siteID
            setState(.ready(siteID: siteID, url: session.previewURL))
        } catch {
            guard gen == generation else { return }
            setState(.failed(siteID: siteID, message: Self.friendlyMessage(for: error)))
        }
    }

    /// Tear down the running container and return to `.idle`. Intentionally fire-and-forget at the
    /// callsite: queued `readabilityHandler`s on the vsock proxy may still fire after teardown but
    /// are idempotent; in-flight bytes are not drained by design.
    public func stop() async {
        generation += 1
        await teardown()
        setState(.idle)
    }

    // MARK: Internals

    private func teardown() async {
        await mcpClient.stop()
        if let siteID = loadedKnowledgeSiteID {
            await knowledgeIndex?.unload(siteID: siteID)
            loadedKnowledgeSiteID = nil
        }
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
        case LocalContainerError.virtualizationUnavailable:
            return "This Mac can't run a local preview — using the remote runtime instead."
        case LocalContainerError.imageUnavailable(let m):
            return "The preview image isn't available: \(m)"
        case LocalContainerError.bootFailed(let m):
            return "Couldn't start the local preview: \(m)"
        case LocalContainerError.cloneFailed(let m):
            return "Couldn't load this site into the preview: \(m)"
        default:
            return "Couldn't start the local preview: \(error)"
        }
    }
}
