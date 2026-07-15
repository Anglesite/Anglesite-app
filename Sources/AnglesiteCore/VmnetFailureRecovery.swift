import Foundation

/// Turns the opaque error emitted by `VmnetNetwork()` into an operator-actionable diagnosis.
///
/// The app is sandboxed and must not inspect or terminate another process's Virtualization XPC
/// VM. In particular, a stale VM can survive its owning container CLI process, so retrying a
/// network creation cannot reliably repair this system-wide state (#753).
public enum VmnetFailureRecovery {
    /// Returns a stable, named recovery message for known vmnet creation failures.
    public static func message(for errorDescription: String) -> String? {
        guard errorDescription.contains("vmnet_return_t(rawValue: 1002)")
        else { return nil }

        return "The macOS vmnet service reported VMNET_MEM_FAILURE (1002). Another VM or a stale "
            + "Virtualization process may still hold vmnet resources. Quit other VM/container apps and retry. "
            + "If it persists, restart your Mac to clear the stale Virtualization state."
    }
}
