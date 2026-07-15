import Testing
@testable import AnglesiteCore

struct VmnetFailureRecoveryTests {
    @Test("VMNET_MEM_FAILURE is named and gives a bounded recovery procedure")
    func diagnosesMemoryFailure() {
        let error = "unsupported: failed to create vmnet network with status vmnet_return_t(rawValue: 1002)"
        let message = VmnetFailureRecovery.message(for: error)

        #expect(message?.contains("VMNET_MEM_FAILURE (1002)") == true)
        #expect(message?.contains("Quit other VM/container apps and retry") == true)
        #expect(message?.contains("restart your Mac") == true)
    }

    @Test("unrelated failures retain their original diagnostic")
    func ignoresUnrelatedFailure() {
        #expect(VmnetFailureRecovery.message(for: "permission denied") == nil)
        #expect(VmnetFailureRecovery.message(for: "vmnet returned 1001") == nil)
        #expect(VmnetFailureRecovery.message(for: "vmnet_return_t(rawValue: 11002)") == nil)
        #expect(VmnetFailureRecovery.message(for: "vmnet_return_t(rawValue: 10021)") == nil)
    }
}
