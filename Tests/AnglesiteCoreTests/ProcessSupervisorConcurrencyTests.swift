import Testing
import Foundation
@testable import AnglesiteCore

/// Regression coverage for the `runOneShot` cooperative-pool deadlock.
///
/// The original defect: `InProcessBackend.runOneShot` awaited the child with the synchronous,
/// run-loop-driven `Process.waitUntilExit()`. Called from `async` actor context it parked a Swift
/// concurrency *cooperative* thread; under enough concurrent one-shot spawns the pool starved and
/// the child-exit notification was never delivered, so `waitUntilExit` blocked forever (observed as
/// a 0%-CPU hang in `swift test`, and as a `brk 1` trap when a concurrent FoundationModels inference
/// was tipped over by the same starvation).
///
/// If the blocking wait is ever reintroduced this test hangs (and CI times out) rather than passing.
struct ProcessSupervisorConcurrencyTests {

    @Test("Many concurrent one-shot runs complete without deadlocking the cooperative pool")
    func concurrentOneShotRunsDoNotDeadlock() async throws {
        // Far more concurrent spawns than the cooperative pool has threads, each on its own
        // supervisor (own `InProcessBackend` actor) exactly as independent call sites use it.
        // A healthy run finishes in well under a second; the pre-fix blocking wait never returns.
        let concurrency = 64
        let iterationsPerTask = 16

        let codes = try await withThrowingTaskGroup(of: [Int32].self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    var results: [Int32] = []
                    for _ in 0..<iterationsPerTask {
                        let supervisor = ProcessSupervisor()
                        let result = try await supervisor.run(
                            executable: URL(fileURLWithPath: "/usr/bin/true")
                        )
                        results.append(result.exitCode)
                    }
                    return results
                }
            }
            var all: [Int32] = []
            for try await chunk in group { all.append(contentsOf: chunk) }
            return all
        }

        #expect(codes.count == concurrency * iterationsPerTask)
        #expect(codes.allSatisfy { $0 == 0 })
    }

    @Test("One-shot output is captured intact under concurrent load")
    func concurrentOneShotRunsCaptureOutput() async throws {
        // Same pressure, but each child prints a unique token — proves the non-blocking exit await
        // still pairs with full pipe drainage (no truncated/missing stdout) when the pool is busy.
        let concurrency = 48

        let outputs = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for i in 0..<concurrency {
                group.addTask {
                    let supervisor = ProcessSupervisor()
                    let result = try await supervisor.run(
                        executable: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "printf 'token-%d' \"$IDX\""],
                        environment: ["IDX": String(i)]
                    )
                    return (i, result.stdout)
                }
            }
            var collected: [Int: String] = [:]
            for try await (i, out) in group { collected[i] = out }
            return collected
        }

        #expect(outputs.count == concurrency)
        for i in 0..<concurrency {
            #expect(outputs[i] == "token-\(i)")
        }
    }
}
