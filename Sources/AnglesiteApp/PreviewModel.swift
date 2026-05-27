import SwiftUI
import AnglesiteBridge
import AnglesiteCore

/// SwiftUI-facing wrapper over a `PreviewSession` actor: mirrors the session's `State` into an
/// observable property and exposes `open(...)` / `close()` for the view layer.
///
/// Owns one `PreviewSession`; opening a different site reuses it (the session tears down the
/// previous one first). For v1 multi-site each window will own its own `PreviewModel`.
@MainActor
@Observable
final class PreviewModel {
    private(set) var state: PreviewSession.State = .idle
    /// The site this model was last asked to open, so the UI can show "preview of X" even while
    /// the session is still `.starting`.
    private(set) var openSiteID: String?

    private let session: PreviewSession

    /// The `EditRouter` that the WKWebView's `AnglesiteScriptHandler` forwards overlay edits to.
    /// Wired to the session's `MCPClient` via a weak getter so the router doesn't outlive the
    /// model. If the MCP client isn't running (session not started yet, or graceful spawn
    /// failure), `MCPApplyEditRouter` returns `.failed("MCP not running")` per its existing shape.
    private(set) var editRouter: EditRouter

    init(session: PreviewSession = PreviewSession()) {
        self.session = session
        self.editRouter = MCPApplyEditRouter(mcpClient: { [weak session] in
            // `session` is the actor instance; reading `mcpClient` is synchronous on the actor.
            await session?.mcpClient
        })
        // Mirror session state into `state`. `[weak self]` so the model can still be freed; the
        // stream itself outlives a freed model (one PreviewModel per window today, so it's moot).
        Task { @MainActor [weak self] in
            for await newState in await session.observe() {
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
                return await self.session.mcpClient
            },
            onEdit: onEdit
        )
    }

    func open(siteID: String, siteDirectory: URL) {
        openSiteID = siteID
        Task { await session.start(siteID: siteID, siteDirectory: siteDirectory) }
    }

    func close() {
        openSiteID = nil
        Task { await session.stop() }
    }

    /// The ready preview URL, if the session is currently `.ready`.
    var readyURL: URL? {
        if case .ready(_, let url) = state { return url }
        return nil
    }

    /// Exposes the session's `MCPClient` via the same weak-getter pattern `editRouter` uses,
    /// so other features (annotation feed for chat, etc.) can reuse the per-site client
    /// without spawning a duplicate MCP server.
    func mcpClient() async -> MCPClient? {
        await session.mcpClient
    }
}
