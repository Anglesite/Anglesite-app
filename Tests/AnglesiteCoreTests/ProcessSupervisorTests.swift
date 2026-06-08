import Testing
import Foundation
@testable import AnglesiteCore

struct ProcessSupervisorTests {
    @Test func `Run captures standard output`() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"]
        )
        #expect(result.stdout == "hello\n")
        #expect(result.stderr == "")
        #expect(result.exitCode == 0)
    }

    @Test func `Run captures standard error`() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf err 1>&2"]
        )
        #expect(result.stdout == "")
        #expect(result.stderr == "err")
        #expect(result.exitCode == 0)
    }

    @Test func `Run reports non-zero exit code`() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"]
        )
        #expect(result.exitCode == 7)
    }

    @Test func `Run throws when executable missing`() async {
        let supervisor = ProcessSupervisor()
        await #expect(throws: ProcessSupervisor.SupervisorError.self) {
            _ = try await supervisor.run(
                executable: URL(fileURLWithPath: "/usr/bin/definitely-not-a-real-binary-xyz"),
                arguments: []
            )
        }
    }

    @Test func `Run passes environment`() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$ANGLESITE_TEST\""],
            environment: ["ANGLESITE_TEST": "phase-1"]
        )
        #expect(result.stdout == "phase-1")
    }
}
