import Testing
@testable import AnglesiteCore

struct LocalContainerSupportTests {
    @Test("available only when all three conditions hold")
    func allThree() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: true, osIsSupported: true, hasVirtualizationEntitlement: true) == true)
        #expect(LocalContainerSupport.availability(isAppleSilicon: true, osIsSupported: true, hasVirtualizationEntitlement: true) == .available)
    }

    @Test("unavailable if not Apple Silicon")
    func notAppleSilicon() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: false, osIsSupported: true, hasVirtualizationEntitlement: true) == false)
        #expect(LocalContainerSupport.availability(isAppleSilicon: false, osIsSupported: true, hasVirtualizationEntitlement: true) == .unavailable([.notAppleSilicon]))
    }

    @Test("unavailable if OS too old")
    func oldOS() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: true, osIsSupported: false, hasVirtualizationEntitlement: true) == false)
        #expect(LocalContainerSupport.availability(isAppleSilicon: true, osIsSupported: false, hasVirtualizationEntitlement: true) == .unavailable([.unsupportedOS]))
    }

    @Test("unavailable without the virtualization entitlement")
    func noEntitlement() {
        #expect(LocalContainerSupport.isAvailable(isAppleSilicon: true, osIsSupported: true, hasVirtualizationEntitlement: false) == false)
        #expect(LocalContainerSupport.availability(isAppleSilicon: true, osIsSupported: true, hasVirtualizationEntitlement: false) == .unavailable([.missingVirtualizationEntitlement]))
    }

    @Test("diagnostic returns every missing gate in stable order")
    func multipleReasons() {
        #expect(LocalContainerSupport.availability(
            isAppleSilicon: false,
            osIsSupported: false,
            hasVirtualizationEntitlement: false
        ) == .unavailable([.notAppleSilicon, .unsupportedOS, .missingVirtualizationEntitlement]))
    }
}
