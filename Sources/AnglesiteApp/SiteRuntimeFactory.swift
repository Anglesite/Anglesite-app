import AnglesiteCore
import AnglesiteContainer

protocol SiteRuntimeFactory: Sendable {
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?
    ) -> any SiteRuntime
}

struct LiveSiteRuntimeFactory: SiteRuntimeFactory {
    private let logCenter: LogCenter

    init(logCenter: LogCenter = .shared) {
        self.logCenter = logCenter
    }

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
        let support = LocalContainerSupport.availability(
            hasVirtualizationEntitlement: VirtualizationEntitlement.isPresent
        )
        let provisioning = BundledImage.provisioningReport
        if support.isAvailable && provisioning.isProvisioned {
            logRuntimeSelection("selected LocalContainerSiteRuntime")
            return LocalContainerSiteRuntime(
                ref: "HEAD",
                control: ContainerizationControl(),
                mcpClient: MCPClient(supervisor: .shared),
                knowledgeIndex: knowledgeIndex,
                semanticRanker: semanticRanker
            )
        }
        logRuntimeSelection(Self.fallbackReason(support: support, provisioning: provisioning))
        return LocalSiteRuntime(contentGraph: contentGraph, knowledgeIndex: knowledgeIndex, semanticRanker: semanticRanker)
    }

    private static func fallbackReason(
        support: LocalContainerSupport.Availability,
        provisioning: BundledImageProvisioningReport
    ) -> String {
        var reasons: [String] = []
        if case .unavailable(let supportReasons) = support {
            reasons.append(contentsOf: supportReasons.map(\.description))
        }
        reasons.append(contentsOf: provisioning.missingDescriptions)
        return "selected LocalSiteRuntime; local container unavailable: \(reasons.joined(separator: "; "))"
    }

    private func logRuntimeSelection(_ text: String) {
        Task {
            await logCenter.append(source: "runtime", stream: .stdout, text: text)
        }
    }
}
