import Testing
@testable import AnglesiteCore

@Suite struct ContentAssistantFactoryTests {
    @Test func makeReturnsBackendMatchingToolchain() {
        let assistant = ContentAssistantFactory.make(tier: .privateCloudCompute)
        #if compiler(>=6.4)
        #expect(assistant != nil)
        #expect(assistant?.capabilities.providerName == "Private Cloud Compute")
        #else
        #expect(assistant == nil)
        #endif
    }
}
