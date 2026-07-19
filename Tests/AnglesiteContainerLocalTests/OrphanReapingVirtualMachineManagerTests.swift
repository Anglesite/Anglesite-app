import Containerization
import Foundation
import Testing
@testable import AnglesiteContainer
import AnglesiteCore

/// Unit tests for the apple/containerization#804 workaround. Pure fakes — no Virtualization
/// framework, no entitlement — so they need only this target's normal `ANGLESITE_CONTAINER_TESTS`
/// build gate, not `ANGLESITE_CONTAINER_E2E` (same story as `RacingTimeoutTests`).
struct OrphanReapingVirtualMachineManagerTests {
    private func makeConfig() -> StandardVMConfig {
        StandardVMConfig(configuration: VMConfiguration())
    }

    @Test("a created VM left .running by a failed boot is stopped by the reap")
    func reapsRunningVM() async throws {
        let vm = FakeVM(state: .running)
        let manager = OrphanReapingVirtualMachineManager(wrapping: FakeVMM(vm: vm))
        _ = try await manager.create(config: makeConfig())

        let log = LogRecorder()
        await manager.reapStranded { line, stream in log.record(line, stream) }

        #expect(vm.stopCallCount == 1)
        #expect(vm.state == .stopped)
        #expect(log.lines.contains { $0.contains("apple/containerization#804") })
    }

    @Test("an already-stopped VM is skipped silently")
    func skipsStoppedVM() async throws {
        let vm = FakeVM(state: .stopped)
        let manager = OrphanReapingVirtualMachineManager(wrapping: FakeVMM(vm: vm))
        _ = try await manager.create(config: makeConfig())

        let log = LogRecorder()
        await manager.reapStranded { line, stream in log.record(line, stream) }

        #expect(vm.stopCallCount == 0)
        #expect(log.lines.isEmpty)
    }

    @Test("a stop failure is surfaced in the log with the manual-recovery hint, not swallowed")
    func logsStopFailure() async throws {
        let vm = FakeVM(state: .running, stopError: FakeVMError.stopRefused)
        let manager = OrphanReapingVirtualMachineManager(wrapping: FakeVMM(vm: vm))
        _ = try await manager.create(config: makeConfig())

        let log = LogRecorder()
        await manager.reapStranded { line, stream in log.record(line, stream) }

        #expect(vm.stopCallCount == 1)
        #expect(log.lines.contains { $0.contains("could not stop") })
        #expect(log.lines.contains { $0.contains("com.apple.Virtualization.VirtualMachine.xpc") })
    }

    @Test("a VM in a state the API cannot stop is logged rather than silently leaked")
    func logsUnstoppableState() async throws {
        let vm = FakeVM(state: .unknown)
        let manager = OrphanReapingVirtualMachineManager(wrapping: FakeVMM(vm: vm))
        _ = try await manager.create(config: makeConfig())

        let log = LogRecorder()
        await manager.reapStranded { line, stream in log.record(line, stream) }

        #expect(vm.stopCallCount == 0)
        #expect(log.lines.contains { $0.contains("cannot stop") })
    }

    @Test("the reap is one-shot: a second call finds nothing to stop")
    func reapIsOneShot() async throws {
        let vm = FakeVM(state: .running)
        let manager = OrphanReapingVirtualMachineManager(wrapping: FakeVMM(vm: vm))
        _ = try await manager.create(config: makeConfig())

        let log = LogRecorder()
        await manager.reapStranded { line, stream in log.record(line, stream) }
        await manager.reapStranded { line, stream in log.record(line, stream) }

        #expect(vm.stopCallCount == 1)
        #expect(log.lines.count == 1)
    }

    @Test("a create failure records nothing, so the reap has nothing to do")
    func createFailureRecordsNothing() async throws {
        let manager = OrphanReapingVirtualMachineManager(wrapping: ThrowingVMM())

        await #expect(throws: FakeVMError.self) {
            _ = try await manager.create(config: self.makeConfig())
        }

        let log = LogRecorder()
        await manager.reapStranded { line, stream in log.record(line, stream) }
        #expect(log.lines.isEmpty)
    }
}

private struct FakeVMM: VirtualMachineManager {
    let vm: FakeVM

    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        vm
    }
}

private struct ThrowingVMM: VirtualMachineManager {
    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        throw FakeVMError.creationFailed
    }
}

/// Minimal `VirtualMachineInstance` whose state and stop behavior the test controls. The dial/
/// listen members are never reached by the wrapper; they throw `unsupported` to satisfy the
/// protocol. Mirrors the codebase's NSLock + `@unchecked Sendable` fake idiom
/// (`FakeNetworkRecorder`, `LineStreamingWriter`).
private final class FakeVM: VirtualMachineInstance, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: VirtualMachineInstanceState
    private let stopError: Error?
    private var _stopCalls = 0

    init(state: VirtualMachineInstanceState, stopError: Error? = nil) {
        self._state = state
        self.stopError = stopError
    }

    var stopCallCount: Int { lock.withLock { _stopCalls } }

    var state: VirtualMachineInstanceState { lock.withLock { _state } }
    var mounts: [String: [AttachedFilesystem]] { [:] }

    func dialAgent() async throws -> Vminitd { throw FakeVMError.unsupported }
    func dial(_ port: UInt32) async throws -> FileHandle { throw FakeVMError.unsupported }
    func listen(_ port: UInt32) throws -> VsockListener { throw FakeVMError.unsupported }

    func start() async throws {
        lock.withLock { _state = .running }
    }

    func stop() async throws {
        lock.withLock { _stopCalls += 1 }
        if let stopError { throw stopError }
        lock.withLock { _state = .stopped }
    }
}

private enum FakeVMError: Error {
    case unsupported
    case stopRefused
    case creationFailed
}

/// Collects `reapStranded`'s `onOutput` lines for assertions. Same locking idiom as `FakeVM`.
private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []

    var lines: [String] { lock.withLock { _lines } }

    func record(_ line: String, _ stream: LogCenter.Stream) {
        lock.withLock { _lines.append(line) }
    }
}
