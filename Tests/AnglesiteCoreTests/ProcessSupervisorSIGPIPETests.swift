import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ProcessSupervisorSIGPIPETests {
    /// Constructing a supervisor must neutralize SIGPIPE process-wide: a write to a pipe whose read
    /// end is closed must return an error instead of killing the process with signal 13 (which would
    /// abort the whole `swift test` run). We trigger a real SIGPIPE via raw POSIX, so simply reaching
    /// the assertion proves the process survived. (Deliberately avoids the `SIG_IGN`/`EPIPE` Swift
    /// constants — they're vended by the `libswift_DarwinFoundation3` overlay the CI runners lack.)
    @Test func writingToClosedPipeDoesNotKillTheProcess() {
        _ = ProcessSupervisor.shared  // forces the install-once SIGPIPE handler

        // Parallel suites spawn real subprocesses, and a child forked between our pipe() and
        // close(readEnd) inherits the read end (spawned fds aren't CLOEXEC by default) — the pipe
        // then still has a live reader, so write() returns 1 instead of raising EPIPE. Mark the
        // fds CLOEXEC to bound that inheritance to the child's pre-exec window, and retry with a
        // fresh pipe if a concurrent spawn stole one.
        var n = 0
        for _ in 0..<5 {
            var fds: [Int32] = [0, 0]
            #expect(pipe(&fds) == 0)
            let readEnd = fds[0]
            let writeEnd = fds[1]
            _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
            close(readEnd)  // closing the read end makes any write to writeEnd raise SIGPIPE

            let byte: [UInt8] = [0x41]
            n = byte.withUnsafeBytes { write(writeEnd, $0.baseAddress, 1) }
            close(writeEnd)
            if n == -1 { break }
        }

        // If SIGPIPE were not neutralized, the write above would terminate the process and we'd
        // never reach this line. The write itself fails (-1) because the read end is gone.
        #expect(n == -1)
    }
}
