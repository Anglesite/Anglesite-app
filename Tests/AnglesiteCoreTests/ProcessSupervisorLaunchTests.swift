import XCTest
@testable import AnglesiteCore

final class ProcessSupervisorLaunchTests: XCTestCase {
    func testLaunchStreamsStdoutLinesToLogCenter() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "stdout-test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'one\\ntwo\\nthree\\n'"],
            logCenter: center
        )
        let reason = await supervisor.waitForExit(handle)
        // Pipe drainage may complete after exit signal; give readers a beat.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(reason, .exited(code: 0))
        let lines = await center.snapshot().filter { $0.source == "stdout-test" && $0.stream == .stdout }
        XCTAssertEqual(lines.map(\.text), ["one", "two", "three"])
    }

    func testLaunchSeparatesStderrFromStdout() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "stderr-test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'out\\n'; printf 'err\\n' 1>&2"],
            logCenter: center
        )
        _ = await supervisor.waitForExit(handle)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = await center.snapshot().filter { $0.source == "stderr-test" }
        let outs = snapshot.filter { $0.stream == .stdout }.map(\.text)
        let errs = snapshot.filter { $0.stream == .stderr }.map(\.text)
        XCTAssertEqual(outs, ["out"])
        XCTAssertEqual(errs, ["err"])
    }

    func testWaitForExitReportsNonZeroCode() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "exit-test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 9"],
            logCenter: center
        )
        let reason = await supervisor.waitForExit(handle)
        XCTAssertEqual(reason, .exited(code: 9))
    }

    func testTerminateStopsLongRunningProcess() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "long",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec sleep 30"],
            logCenter: center
        )
        // Let it actually start.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let runningBefore = await supervisor.isRunning(handle)
        XCTAssertTrue(runningBefore)

        await supervisor.terminate(handle, timeout: 2)
        let reason = await supervisor.waitForExit(handle)
        XCTAssertEqual(reason, .terminated)
        let runningAfter = await supervisor.isRunning(handle)
        XCTAssertFalse(runningAfter)
    }

    func testRestartOnCrashGivesUpAfterMaxAttempts() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "crashy",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo boom 1>&2; exit 2"],
            restartPolicy: .onCrash(maxAttempts: 2, baseBackoff: 0.0),
            logCenter: center
        )
        let reason = await supervisor.waitForExit(handle)
        // Pipe drainage may lag the exit signal.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(reason, .retriesExhausted(lastCode: 2))
        let boomCount = await center.snapshot().filter {
            $0.source == "crashy" && $0.text == "boom"
        }.count
        // Initial attempt + 2 retries = 3 emissions of "boom".
        XCTAssertEqual(boomCount, 3)
    }

    func testRestartOnCrashStopsAfterCleanExit() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "clean",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"],
            restartPolicy: .onCrash(maxAttempts: 5, baseBackoff: 0.0),
            logCenter: center
        )
        let reason = await supervisor.waitForExit(handle)
        XCTAssertEqual(reason, .exited(code: 0))
    }

    func testLaunchAttachStdinAllowsWrites() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        // `cat` echoes whatever we feed it; then we close stdin and it exits cleanly.
        let handle = try await supervisor.launch(
            source: "cat",
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            attachStdin: true,
            logCenter: center
        )
        guard let stdin = await supervisor.stdinWriter(handle) else {
            XCTFail("expected stdin writer")
            return
        }
        try stdin.writer.write(contentsOf: Data("hello\n".utf8))
        try stdin.writer.close()

        let reason = await supervisor.waitForExit(handle)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(reason, .exited(code: 0))
        let lines = await center.snapshot().filter { $0.source == "cat" && $0.stream == .stdout }.map(\.text)
        XCTAssertEqual(lines, ["hello"])
    }
}
