import XCTest
@testable import AnglesiteCore

final class ProcessSupervisorShutdownTests: XCTestCase {
    func testShutdownAllTerminatesEverySupervisedProcess() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()

        var handles: [ProcessSupervisor.Handle] = []
        for i in 0..<3 {
            let h = try await supervisor.launch(
                source: "long-\(i)",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec sleep 30"],
                logCenter: center
            )
            handles.append(h)
        }
        // Let them actually start.
        try? await Task.sleep(nanoseconds: 150_000_000)
        for h in handles {
            let running = await supervisor.isRunning(h)
            XCTAssertTrue(running)
        }

        await supervisor.shutdownAll(timeout: 2)

        for h in handles {
            let reason = await supervisor.waitForExit(h)
            XCTAssertEqual(reason, .terminated)
            let running = await supervisor.isRunning(h)
            XCTAssertFalse(running)
        }
    }

    func testShutdownAllOnIdleSupervisorReturnsImmediately() async {
        let supervisor = ProcessSupervisor()
        // No processes launched — must not hang.
        await supervisor.shutdownAll(timeout: 1)
    }

    func testShutdownAllStopsRestartingCrashLoopedProcess() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        // A process that crashes immediately, configured to retry many times with a
        // small backoff. shutdownAll must break the restart loop, not wait it out.
        let handle = try await supervisor.launch(
            source: "crashloop",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 3"],
            restartPolicy: .onCrash(maxAttempts: 100, baseBackoff: 0.2),
            logCenter: center
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        await supervisor.shutdownAll(timeout: 1)

        let reason = await supervisor.waitForExit(handle)
        XCTAssertEqual(reason, .terminated)
    }
}
