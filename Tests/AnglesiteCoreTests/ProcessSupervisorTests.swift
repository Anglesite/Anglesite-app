import XCTest
@testable import AnglesiteCore

final class ProcessSupervisorTests: XCTestCase {
    func testRunCapturesStandardOutput() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"]
        )
        XCTAssertEqual(result.stdout, "hello\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testRunCapturesStandardError() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf err 1>&2"]
        )
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testRunReportsNonZeroExitCode() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"]
        )
        XCTAssertEqual(result.exitCode, 7)
    }

    func testRunThrowsWhenExecutableMissing() async {
        let supervisor = ProcessSupervisor()
        do {
            _ = try await supervisor.run(
                executable: URL(fileURLWithPath: "/usr/bin/definitely-not-a-real-binary-xyz"),
                arguments: []
            )
            XCTFail("expected spawnFailed")
        } catch ProcessSupervisor.SupervisorError.spawnFailed {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRunPassesEnvironment() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$ANGLESITE_TEST\""],
            environment: ["ANGLESITE_TEST": "phase-1"]
        )
        XCTAssertEqual(result.stdout, "phase-1")
    }
}
