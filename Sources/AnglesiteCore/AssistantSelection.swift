import Foundation

// Compiler-gated because `FoundationModelAssistant`/`ClaudeAssistant` require Swift 6.4 (#128).
#if compiler(>=6.4)

/// Conversational backend to construct for a site session.
public enum AssistantSelection: Sendable, Equatable {
    /// Claude via the bundled `claude` CLI (DevID only; never selected in the MAS build).
    case claude
    /// Apple's on-device FoundationModels at the given tier.
    case foundationModel(tier: FoundationModelTier)

    // `.foundationModel` always attaches editBridge + contentGraph — invariant lives here, not in callers.
    public func makeAssistant(
        siteID: String,
        siteDirectory: URL,
        contentGraph: SiteContentGraph
    ) -> any ConversationalAssistant {
        switch self {
        case .claude:
            return ClaudeAssistant(siteID: siteID, siteDirectory: siteDirectory)
        case .foundationModel(let tier):
            let editBridge = IntentEditBridge(
                routerProvider: { id in await EditRouterRegistry.shared.router(for: id) }
            )
            return FoundationModelAssistant(tier: tier, editBridge: editBridge, contentGraph: contentGraph)
        }
    }
}
#endif
