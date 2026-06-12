import SwiftUI
import AnglesiteBridge
import AnglesiteCore

/// SwiftUI-facing wrapper over a `SiteRuntime` actor: mirrors the runtime's `SiteRuntimeState` into
/// an observable property and exposes `open(...)` / `close()` for the view layer.
///
/// Owns one `SiteRuntime`; opening a different site reuses it (the runtime tears down the previous
/// one first). For v1 multi-site each window will own its own `PreviewModel`.
@MainActor
@Observable
final class PreviewModel {
    private(set) var state: SiteRuntimeState = .idle
    /// The site this model was last asked to open, so the UI can show "preview of X" even while
    /// the runtime is still `.starting`.
    private(set) var openSiteID: String?

    private let runtime: any SiteRuntime

    /// The `EditRouter` that the WKWebView's `AnglesiteScriptHandler` forwards overlay edits to.
    /// Wired to the runtime's `MCPClient` via a weak getter so the router doesn't outlive the
    /// model. If the MCP client isn't running (runtime not started yet, or graceful spawn
    /// failure), `MCPApplyEditRouter` returns `.failed("MCP not running")` per its existing shape.
    private(set) var editRouter: EditRouter

    /// `contentGraph` is the app-lifetime `SiteContentGraph` (held by `AppDelegate`); it's threaded
    /// into the default `LocalSiteRuntime` so opening this site populates the shared graph (A.8,
    /// #142). Tests inject an explicit `runtime` and leave the graph `nil`.
    init(contentGraph: SiteContentGraph? = nil, runtime: (any SiteRuntime)? = nil) {
        let runtime = runtime ?? LocalSiteRuntime(contentGraph: contentGraph)
        self.runtime = runtime
        self.editRouter = MCPApplyEditRouter(mcpClient: { [weak runtime] in
            // `runtime` is the actor instance; reading `mcpClient` hops onto the actor.
            await runtime?.mcpClient
        })
        // Mirror runtime state into `state`. `[weak self]` so the model can still be freed; the
        // stream itself outlives a freed model (one PreviewModel per window today, so it's moot).
        Task { @MainActor [weak self] in
            for await newState in await runtime.observe() {
                self?.state = newState
            }
        }
    }

    /// Re-build the edit router with an observer attached. Called by `SiteWindow.loadAndStart`
    /// after `ChatModel` is constructed, so each successful `apply_edit` reply also fires
    /// `ChatModel.recordEdit(_:)` — surfacing the edit as an `.edit` row in the chat panel.
    ///
    /// Subsequent calls replace the prior observer (the router is fully reconstructed each time
    /// with the same `mcpClient` getter; `MCPApplyEditRouter` is a struct so this is cheap).
    func setEditObserver(_ onEdit: @escaping MCPApplyEditRouter.EditObserver) {
        self.editRouter = MCPApplyEditRouter(
            mcpClient: { [weak self] in
                guard let self else { return nil }
                return await self.runtime.mcpClient
            },
            onEdit: onEdit
        )
    }

    func open(siteID: String, siteDirectory: URL) {
        openSiteID = siteID
        Task { await runtime.start(siteID: siteID, siteDirectory: siteDirectory) }
    }

    func close() {
        openSiteID = nil
        Task { await runtime.stop() }
    }

    /// The ready preview URL, if the session is currently `.ready`.
    var readyURL: URL? {
        if case .ready(_, let url) = state { return url }
        return nil
    }

    /// Exposes the runtime's `MCPClient` via the same weak-getter pattern `editRouter` uses,
    /// so other features (annotation feed for chat, etc.) can reuse the per-site client
    /// without spawning a duplicate MCP server.
    func mcpClient() async -> MCPClient? {
        await runtime.mcpClient
    }
}
