import Testing
@testable import AnglesiteCore

struct LocalContainerSupportTests {
    @Test("available only when all three conditions hold")
    func allThree() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: true, osIsSupported: true, hasVirtualizationEntitlement: true) == true)
    }

    @Test("unavailable if not Apple Silicon")
    func notAppleSilicon() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: false, osIsSupported: true, hasVirtualizationEntitlement: true) == false)
    }

    @Test("unavailable if OS too old")
    func oldOS() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: true, osIsSupported: false, hasVirtualizationEntitlement: true) == false)
    }

    @Test("unavailable without the virtualization entitlement")
    func noEntitlement() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: true, osIsSupported: true, hasVirtualizationEntitlement: false) == false)
    }
}
