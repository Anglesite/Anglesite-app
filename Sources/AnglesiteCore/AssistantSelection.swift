import Foundation

// Gated like the assistants it constructs — `FoundationModelAssistant`/`ClaudeAssistant` are both
// inside `#if compiler(>=6.4)` (FoundationModels is absent at runtime on CI, #128). The SwiftUI call
// site is already 6.4-only by the same assumption.
#if compiler(>=6.4)

/// Which conversational backend a `SiteWindow` should construct for a site.
///
/// The MAS-vs-DevID target split and the DevID `preferFoundationModels` toggle are resolved at the
/// SwiftUI call site — the `#if ANGLESITE_MAS` compilation condition is a no-op inside this SPM
/// package (see CLAUDE.md), so it can't live here. The call site collapses that decision into one of
/// these cases and hands it to ``makeAssistant(siteID:siteDirectory:contentGraph:)``, keeping the
/// actual construction — and the invariant that the on-device path is *always* tool-equipped — in one
/// testable place rather than inline in a `View` method.
public enum AssistantSelection: Sendable, Equatable {
    /// Claude via the bundled `claude` CLI (DevID only; never selected in the MAS build).
    case claude
    /// Apple's on-device FoundationModels at the given tier.
    case foundationModel(tier: FoundationModelTier)

    /// Builds the `ConversationalAssistant` for this selection.
    ///
    /// The `.foundationModel` case is why this is centralized: it *always* attaches the per-site
    /// `IntentEditBridge` + `contentGraph`, so the on-device assistant advertises `supportsTools` and
    /// runs the local `ApplyEditTool` + `SearchContentTool` loop with no network (#193). A regression
    /// that drops either collaborator is now a single-site fix caught by `AssistantSelectionTests`,
    /// instead of passing silently in a `View` method.
    ///
    /// The edit bridge is built only in the on-device case (`.claude` needs none) and is stateless —
    /// keyed on the `siteID` passed to `applyEdit` at call time — so it resolves the live router from
    /// `EditRouterRegistry` lazily and a fresh instance per call is correct.
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
