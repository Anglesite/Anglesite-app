import AnglesiteContainer
import AnglesiteCore

struct LiveSiteRuntimeFactory: SiteRuntimeFactory {
    private let logCenter: LogCenter
    private let settings: AppSettings

    init(logCenter: LogCenter = .shared, settings: AppSettings = .shared) {
        self.logCenter = logCenter
        self.settings = settings
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
        // LAN runtime (#589/#601): dev/test-only fallback for hosts that can't boot the local
        // container (e.g. a UTM guest VM, where kern.hv_support == 0). Only reachable when the
        // Settings → Advanced override is set — absent that, behavior is unchanged below.
        if let lan = settings.lanRuntimeConfiguration {
            logRuntimeSelection(
                "selected RemoteSandboxSiteRuntime via LAN host \(lan.host) "
                + "(preview :\(lan.previewPort), mcp :\(lan.mcpPort)); "
                + Self.fallbackReason(support: support, provisioning: provisioning))
            return RemoteSandboxSiteRuntime(
                gitRemote: LANControlClient.unusedGitRemote,
                gitRef: "HEAD",
                control: LANControlClient(configuration: lan),
                mcpClient: MCPClient(supervisor: .shared),
                connect: { client, url, _ in
                    // Trusted-LAN path: the host process doesn't know the guest-minted token,
                    // so connect without a bearer (design note 2026-07-09, non-goals).
                    try await client.connect(httpEndpoint: url)
                }
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
