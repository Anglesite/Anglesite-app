import Foundation
import AnglesiteCore
import Containerization

/// Retains a reference to every VM instance the wrapped `VirtualMachineManager` creates, so a
/// failed boot can stop a VM that upstream stranded.
///
/// This is the app-side patch for apple/containerization#804 (present in the pinned 0.35 line):
/// inside `LinuxContainer.create()`, `try await vm.start()` runs *outside* the `do/catch` whose
/// failure path calls `vm.stop()` (`LinuxContainer.swift:587-591` at 0.35.0), so a start-time
/// throw strands the freshly created `VZVirtualMachineInstance` as a local variable nothing can
/// reach. The stranded VM's `com.apple.Virtualization.VirtualMachine.xpc` helper keeps running —
/// holding the VM's vmnet interface and its 2 vCPU / 2 GB — until someone kills it by PID (#785).
/// `LinuxContainer.stop()` can never release it either: the `create()` throw means the container
/// never reached `.created`, so `stop()` bails on its state check before touching the VM.
///
/// What's recoverable is the class where the underlying VZ VM did start and `vm.start()` threw
/// afterwards (the vminitd agent handshake — `waitForAgent` / `Vminitd` init — the same class as
/// #498's hang-then-late-failure boots): the VM reports `.running`, and `stop()` works. A VM whose
/// VZ-level start itself failed reports `.stopped` and holds nothing the Containerization API can
/// release (`VZVirtualMachineInstance.stop()` deliberately throws unless `.running`). That is also
/// why forking upstream to move `vm.start()` inside its `do/catch` — the fix proposed in
/// containerization#804 — would recover no more than this wrapper: that patch is the same
/// `try? await vm.stop()` against the same state guard, and the public `VirtualMachineManager`
/// seam already lets the app hold the reference upstream drops, without carrying a fork.
///
/// Scoped per boot attempt: `makeBareContainer` wraps a fresh `VZVirtualMachineManager` per call
/// and `LinuxContainer.create()` calls `vmm.create` exactly once, so at most one instance is ever
/// recorded. `reapStranded` runs only on the failure paths that call `stopBareContainer`, and
/// always after it — a VM the container *could* stop is `.stopped` by then and skipped; only a
/// genuinely stranded one is still `.running`.
final class OrphanReapingVirtualMachineManager: VirtualMachineManager, @unchecked Sendable {
    private let wrapped: any VirtualMachineManager
    private let lock = NSLock()
    private var created: [any VirtualMachineInstance] = []

    init(wrapping wrapped: any VirtualMachineManager) {
        self.wrapped = wrapped
    }

    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        let vm = try await wrapped.create(config: config)
        lock.withLock { created.append(vm) }
        return vm
    }

    /// Best-effort stop of every recorded VM the failed boot left `.running`. One-shot: reaped
    /// instances are dropped from the record, and `.stopped`/`.stopping` ones are skipped silently
    /// (the normal shape — `stopBareContainer` got there first, or VZ-level start never happened
    /// and there is nothing to release). Anything else is logged rather than silently leaked
    /// ("logs are sacred"), including the manual-recovery hint from #785.
    func reapStranded(onOutput: @Sendable (String, LogCenter.Stream) -> Void) async {
        let instances = lock.withLock {
            let snapshot = created
            created.removeAll()
            return snapshot
        }
        for vm in instances {
            switch vm.state {
            case .stopped, .stopping:
                continue
            case .running:
                do {
                    try await vm.stop()
                    onOutput(
                        "[boot] stopped a VM stranded by the failed boot (apple/containerization#804)",
                        .stderr)
                } catch {
                    onOutput(
                        "[boot] could not stop the VM stranded by the failed boot: \(error) — if "
                            + "boots keep failing, check for a leftover "
                            + "com.apple.Virtualization.VirtualMachine.xpc process (#785)",
                        .stderr)
                }
            case .starting, .unknown:
                onOutput(
                    "[boot] a VM stranded by the failed boot is in state \(vm.state), which the "
                        + "Containerization API cannot stop; if boots keep failing, check for a "
                        + "leftover com.apple.Virtualization.VirtualMachine.xpc process (#785)",
                    .stderr)
            }
        }
    }
}
