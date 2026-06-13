import Testing
import Foundation
@testable import AnglesiteCore

// Gated like the type under test (#128). Capability/tier assertions run on any toolchain≥6.4;
// the generate/generateStructured tests are live-model and skip when unavailable.
// TODO(#104/#161): migrate the live tests to the mock LanguageModel session once #104 lands.
#if compiler(>=6.4)
import FoundationModels

@Suite("FoundationModelAssistant")
struct FoundationModelAssistantTests {

    private func makeContext() -> AssistantContext {
        AssistantContext(siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
    }

    private func modelAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    // MARK: Capabilities / tier (no model required)

    @Test("on-device tier advertises the on-device capabilities")
    func onDeviceCapabilities() {
        let caps = FoundationModelAssistant(tier: .onDevice).capabilities
        #expect(caps.providerName == "On-Device")
        #expect(caps.maxContextTokens == 4_096)
        #expect(caps.supportsStreaming)
        #expect(caps.supportsStructuredOutput)
        #expect(!caps.supportsTools)
        #expect(!caps.supportsVision)
    }

    @Test("PCC tier advertises a larger context window and PCC provider name")
    func pccCapabilities() {
        let caps = FoundationModelAssistant(tier: .privateCloudCompute).capabilities
        #expect(caps.providerName == "Private Cloud Compute")
        #expect(caps.maxContextTokens == 32_768)
    }

    @Test("default tier is on-device")
    func defaultTierIsOnDevice() {
        #expect(FoundationModelAssistant().capabilities.providerName == "On-Device")
    }

    @Test("PCC-tier assistant constructs and remains usable (falls back to on-device)")
    func pccConstructsAndIsUsable() async {
        let assistant = FoundationModelAssistant(tier: .privateCloudCompute)
        #expect(await assistant.capabilities.maxContextTokens == 32_768)
    }

    // MARK: Error path (meaningful only on a host WITHOUT the model)

    @Test("generate surfaces AssistantError.unavailable when the model is absent")
    func generateUnavailableSurfacesError() async {
        guard !modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        await #expect(throws: AssistantError.self) {
            _ = try await assistant.generate(prompt: "hi", context: makeContext())
        }
    }

    // MARK: Live paths (skip when the model is unavailable)

    @Test("generate streams non-empty text")
    func generateStreamsText() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        var collected = ""
        for try await chunk in try await assistant.generate(prompt: "Say hello in one short sentence.", context: makeContext()) {
            collected += chunk
        }
        #expect(!collected.isEmpty)
    }

    @Test("generateStructured returns the requested Generable type")
    func generateStructuredReturnsType() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        let result = try await assistant.generateStructured(
            prompt: "Generate page metadata for a contact page.",
            context: makeContext(),
            resultType: GeneratedPageMeta.self
        )
        #expect(!result.title.isEmpty)
    }
}
#endif
