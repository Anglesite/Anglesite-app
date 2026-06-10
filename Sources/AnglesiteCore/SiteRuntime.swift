import Foundation

/// The lifecycle state of one site's live preview, independent of *where* it runs (host subprocess
/// today via `LocalSiteRuntime`; a Cloudflare Sandbox or local Apple-Containerization VM later).
public enum SiteRuntimeState: Sendable, Equatable {
    case idle
    case starting(siteID: String)
    case ready(siteID: String, url: URL)
    /// Couldn't preview this site (deps not installed, dev server crashed, etc.). `message` is
    /// shown to the owner; the Debug pane has the full subprocess output.
    case failed(siteID: String, message: String)
}

/// One runtime = one site's live preview. This is the seam for swapping execution substrates
/// (see #59 / design doc §4): a container exposes an HTTP/WS URL rather than a pid + pipes, so the
/// abstraction lives here — at `PreviewSession`'s old level — not at `SupervisorBackend`.
///
/// `start(siteID:siteDirectory:)` tears down any previous site first and settles to `.ready` /
/// `.failed`; `observe()` streams every `SiteRuntimeState` transition; `mcpClient` is the per-site
/// MCP connection the edit pipeline and annotation feed route through.
///
/// Refines `Actor`: every conformer owns mutable lifecycle state (subprocess handles today, a
/// remote session later), so isolation is intrinsic — and a class-bound existential keeps the
/// `[weak]` capture `PreviewModel` uses for its edit router valid.
///
/// `mcpClient` is the concrete stdio `MCPClient` for now. When #64 lands an HTTP/WS transport this
/// getter becomes the substrate-agnostic seam (an endpoint-backed client for the container paths).
public protocol SiteRuntime: Actor {
    func start(siteID: String, siteDirectory: URL) async
    func stop() async
    func observe() -> AsyncStream<SiteRuntimeState>
    var mcpClient: MCPClient { get }
}
