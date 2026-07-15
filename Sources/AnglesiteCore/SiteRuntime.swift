import Foundation

/// The lifecycle state of one site's live preview, independent of where it runs.
public enum SiteRuntimeState: Sendable, Equatable {
    case idle
    case starting(siteID: String)
    case ready(siteID: String, url: URL)
    /// Couldn't preview this site (deps not installed, dev server crashed, etc.). `message` is
    /// shown to the owner; the Debug pane has the full subprocess output.
    case failed(siteID: String, message: String)
}

/// Failures that prevent a runtime edit from becoming durable in the canonical `Source/` repo.
public enum SiteRuntimePersistenceError: LocalizedError, Sendable, Equatable {
    case missingOrInvalidCommit
    case runtimeNotRunning
    case syncFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingOrInvalidCommit:
            "the edit server did not return a valid git commit"
        case .runtimeNotRunning:
            "the site runtime is no longer running"
        case .syncFailed(let message):
            message
        }
    }
}

/// One runtime = one site's live preview. This is the seam for swapping execution substrates
/// (see #59 / design doc §4): a container exposes an HTTP/WS URL rather than a pid + pipes, so the
/// abstraction lives here — at `PreviewSession`'s old level — not at `SupervisorBackend`.
///
/// `start(siteID:siteDirectory:)` tears down any previous site first and settles to `.ready` /
/// `.failed`; `observe()` streams every `SiteRuntimeState` transition; `mcpClient` is the per-site
/// MCP connection the edit pipeline and annotation feed route through.
///
/// Refines `Actor`: every conformer owns mutable lifecycle state, so isolation is intrinsic — and a class-bound existential keeps the
/// `[weak]` capture `PreviewModel` uses for its edit router valid.
///
/// `mcpClient` is the substrate-agnostic MCP seam for the running container endpoint.
public protocol SiteRuntime: Actor {
    func start(siteID: String, siteDirectory: URL) async
    func stop() async
    func observe() -> AsyncStream<SiteRuntimeState>
    var mcpClient: MCPClient { get }
}
