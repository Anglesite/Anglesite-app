import Testing
import Foundation
@testable import AnglesiteCore

struct ProcessSupervisorLaunchTests {
    @Test func `Launch streams stdout lines to log center`() async throws {
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

        #expect(reason == .exited(code: 0))
        let lines = await center.snapshot().filter { $0.source == "stdout-test" && $0.stream == .stdout }
        #expect(lines.map(\.text) == ["one", "two", "three"])
    }

    @Test func `Launch separates stderr from stdout`() async throws {
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
        #expect(outs == ["out"])
        #expect(errs == ["err"])
    }

    @Test func `Wait for exit reports non-zero code`() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let handle = try await supervisor.launch(
            source: "exit-test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 9"],
            logCenter: center
        )
        let reason = await supervisor.waitForExit(handle)
        #expect(reason == .exited(code: 9))
    }

    @Test func `Terminate stops long-running process`() async throws {
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
        #expect(runningBefore)

        await supervisor.terminate(handle, timeout: 2)
        let reason = await supervisor.waitForExit(handle)
        #expect(reason == .terminated)
        let runningAfter = await supervisor.isRunning(handle)
        #expect(!runningAfter)
    }

    @Test func `Restart on crash gives up after max attempts`() async throws {
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

        #expect(reason == .retriesExhausted(lastCode: 2))
        let boomCount = await center.snapshot().filter {
            $0.source == "crashy" && $0.text == "boom"
        }.count
        // Initial attempt + 2 retries = 3 emissions of "boom".
        #expect(boomCount == 3)
    }

    @Test func `Restart on crash stops after clean exit`() async throws {
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
        #expect(reason == .exited(code: 0))
    }

    @Test func `On respawn fires once per successful restart`() async throws {
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

        #expect(reason == .retriesExhausted(lastCode: 4))
        // Initial spawn doesn't count; 3 retries → 3 respawn callbacks.
        let count = await respawns.value
        #expect(count == 3)
    }

    @Test func `On respawn not called when process never crashes`() async throws {
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
        #expect(count == 0)
    }

    @Test func `Launch attach stdin allows writes`() async throws {
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
        let stdin = try #require(await supervisor.stdinWriter(handle), "expected stdin writer")
        try stdin.writer.write(contentsOf: Data("hello\n".utf8))
        try stdin.writer.close()

        let reason = await supervisor.waitForExit(handle)
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(reason == .exited(code: 0))
        let lines = await center.snapshot().filter { $0.source == "cat" && $0.stream == .stdout }.map(\.text)
        #expect(lines == ["hello"])
    }
}

private actor RespawnCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
