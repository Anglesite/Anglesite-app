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

        let snapshot = await center.snapshot().filter { $0.source == "stderr-test" }
        let outs = snapshot.filter { $0.stream == .stdout }.map(\.text)
        let errs = snapshot.filter { $0.stream == .stderr }.map(\.text)
        XCTAssertEqual(outs, ["out"])
        XCTAssertEqual(errs, ["err"])
    }

    /// Regression: `waitForExit` must not resume until every byte read from the child's
    /// stdout/stderr is in `LogCenter`. The previous pump fired untracked
    /// `Task { await logCenter.append }` from the readabilityHandler, so a snapshot taken
    /// immediately after `waitForExit` could miss the tail of the output — `DeployCommand`
    /// papered over the gap with a 100ms sleep, and `DeployCommandTests` still flaked under
    /// CI load. This test runs the burst-then-exit pattern that triggered the flake (lots of
    /// output crammed into the last few milliseconds before exit) and asserts that the very
    /// last line is present in the snapshot with zero post-exit sleep.
    func testSnapshotIncludesLastLineAfterWaitForExitWithoutSleep() async throws {
        for _ in 0..<25 {
            let supervisor = ProcessSupervisor()
            let center = LogCenter()
            let handle = try await supervisor.launch(
                source: "drain-race",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    // Burst a few lines, then write a sentinel right before exiting. If the
                    // pump ever loses the tail, this test will fail on the sentinel.
                    "for i in 1 2 3 4 5 6 7 8 9 10; do printf 'line %s\\n' $i; done; printf 'SENTINEL\\n'"
                ],
                logCenter: center
            )
            _ = await supervisor.waitForExit(handle)
            let lines = await center.snapshot()
                .filter { $0.source == "drain-race" && $0.stream == .stdout }
                .map(\.text)
            XCTAssertEqual(lines.last, "SENTINEL", "last stdout line must be in LogCenter the moment waitForExit returns")
            XCTAssertEqual(lines.count, 11, "all lines must be present, none lost: \(lines)")
        }
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

    func testOnRespawnFiresOncePerSuccessfulRestart() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let respawns = RespawnCounter()
        let handle = try await supervisor.launch(
            source: "respawn-test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 4"],
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.0),
            onRespawn: { await respawns.bump() },
            logCenter: center
        )
        let reason = await supervisor.waitForExit(handle)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(reason, .retriesExhausted(lastCode: 4))
        // Initial spawn doesn't count; 3 retries → 3 respawn callbacks.
        let count = await respawns.value
        XCTAssertEqual(count, 3)
    }

    func testOnRespawnNotCalledWhenProcessNeverCrashes() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let respawns = RespawnCounter()
        let handle = try await supervisor.launch(
            source: "no-respawn",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"],
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.0),
            onRespawn: { await respawns.bump() },
            logCenter: center
        )
        _ = await supervisor.waitForExit(handle)
        let count = await respawns.value
        XCTAssertEqual(count, 0)
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

private actor RespawnCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
