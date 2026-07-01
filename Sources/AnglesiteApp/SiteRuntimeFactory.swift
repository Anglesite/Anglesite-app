import AnglesiteCore

// AnglesiteContainer links into the DevID app only; the MAS target intentionally
// falls back to the host subprocess runtime.
#if !ANGLESITE_MAS
import AnglesiteContainer
#endif

protocol SiteRuntimeFactory: Sendable {
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?
    ) -> any SiteRuntime
}

struct LiveSiteRuntimeFactory: SiteRuntimeFactory {
    /// Pick the runtime by capability (no feature flag): a local Apple-Containerization VM when the
    /// build is entitled + the kernel/initfs are provisioned; otherwise the existing host-subprocess
    /// runtime.
    ///
    /// `sourceRepo` is not passed here. Container runtimes receive it at
    /// `start(siteID:siteDirectory:)` time.
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?
    ) -> any SiteRuntime {
        #if !ANGLESITE_MAS
        if LocalContainerSupport.isAvailable(hasVirtualizationEntitlement: VirtualizationEntitlement.isPresent)
            && BundledImage.isProvisioned {
            return LocalContainerSiteRuntime(
                ref: "HEAD",
                control: ContainerizationControl(),
                mcpClient: MCPClient(supervisor: .shared),
                knowledgeIndex: knowledgeIndex,
                semanticRanker: semanticRanker
            )
        }
        #endif
        return LocalSiteRuntime(contentGraph: contentGraph, knowledgeIndex: knowledgeIndex, semanticRanker: semanticRanker)
    }
}
