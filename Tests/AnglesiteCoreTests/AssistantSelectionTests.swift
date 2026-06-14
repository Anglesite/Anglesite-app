import Testing
import Foundation
@testable import AnglesiteCore

// Gated like the type under test — it constructs the 6.4-gated assistants (#128).
#if compiler(>=6.4)

/// Covers the `SiteWindow.loadAndStart` wiring seam that unit tests previously missed (#193 review):
/// that the on-device *selection* always yields a tool-equipped assistant. The capabilities are the
/// observable signal — if a future change drops the `IntentEditBridge`/`contentGraph` inside
/// `makeAssistant`, `supportsTools` flips to `false` and these fail.
@Suite("AssistantSelection.makeAssistant")
struct AssistantSelectionTests {
    private let siteID = "site-1"
    private let dir = URL(fileURLWithPath: "/tmp/site")

    @Test("on-device selection yields a tool-equipped FoundationModelAssistant")
    func onDeviceIsToolEquipped() {
        let assistant = AssistantSelection.foundationModel(tier: .onDevice)
            .makeAssistant(siteID: siteID, siteDirectory: dir, contentGraph: SiteContentGraph())
        let caps = assistant.capabilities
        #expect(caps.providerName == "On-Device")
        #expect(caps.supportsTools)
    }

    @Test("PCC-tier selection also yields a tool-equipped assistant")
    func pccIsToolEquipped() {
        let assistant = AssistantSelection.foundationModel(tier: .privateCloudCompute)
            .makeAssistant(siteID: siteID, siteDirectory: dir, contentGraph: SiteContentGraph())
        let caps = assistant.capabilities
        #expect(caps.providerName == "Private Cloud Compute")
        #expect(caps.supportsTools)
    }

    @Test("claude selection yields the Claude backend")
    func claudeSelectionYieldsClaude() {
        let assistant = AssistantSelection.claude
            .makeAssistant(siteID: siteID, siteDirectory: dir, contentGraph: SiteContentGraph())
        #expect(assistant.capabilities.providerName == "Claude")
    }
}
#endif
