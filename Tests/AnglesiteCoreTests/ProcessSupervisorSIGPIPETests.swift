import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ProcessSupervisorSIGPIPETests {
    /// Constructing any supervisor must leave `SIGPIPE` ignored process-wide, so a write to a child
    /// whose read end has closed fails with `EPIPE` instead of killing the process with signal 13
    /// (which aborts `swift test --parallel` with no failing-test marker — the CI failure this fixes).
    @Test func ignoresSIGPIPEAfterConstruction() async {
        _ = ProcessSupervisor.shared  // forces the install-once static to run
        var action = sigaction()
        _ = sigaction(SIGPIPE, nil, &action)
        let current = unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
        let ignore = unsafeBitCast(SIG_IGN, to: UInt.self)
        #expect(current == ignore)
    }
}
