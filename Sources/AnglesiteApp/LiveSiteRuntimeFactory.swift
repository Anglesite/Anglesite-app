import AnglesiteContainer
import AnglesiteCore

struct LiveSiteRuntimeFactory: SiteRuntimeFactory {
    private let logCenter: LogCenter

    init(logCenter: LogCenter = .shared) {
        self.logCenter = logCenter
    }

    /// Pick the runtime by capability (no feature flag): a local Apple-Containerization VM when the
    /// build is entitled + the kernel/initfs are provisioned. The old host-subprocess fallback is
    /// intentionally gone (#70); when the container path is unavailable this returns an explicit
    /// failed runtime so validation cannot accidentally pass through embedded Node.
    ///
    /// `sourceRepo` is not passed here. Container runtimes receive it at
    /// `start(siteID:siteDirectory:)` time.
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?
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
                semanticRanker: semanticRanker,
                conventionsEngine: conventionsEngine
            )
        }
        logRuntimeSelection(Self.fallbackReason(support: support, provisioning: provisioning))
        return UnavailableSiteRuntime(reason: Self.unavailableMessage(support: support, provisioning: provisioning))
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
        return "no host runtime fallback; local container unavailable: \(reasons.joined(separator: "; "))"
    }

    private static func unavailableMessage(
        support: LocalContainerSupport.Availability,
        provisioning: BundledImageProvisioningReport
    ) -> String {
        let reason = fallbackReason(support: support, provisioning: provisioning)
        return "Local container runtime is required, but it is not available yet (\(reason))."
    }

    private func logRuntimeSelection(_ text: String) {
        Task {
            await logCenter.append(source: "runtime", stream: .stdout, text: text)
        }
    }
}
