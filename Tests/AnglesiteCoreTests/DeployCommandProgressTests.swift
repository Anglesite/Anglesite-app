// Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct DeployCommandProgressTests {
    @Test("a blocked deploy still emits building then preflight milestones")
    func milestonesUpToBlock() async {
        let recorder = ProgressRecorder()
        // Build resolves to `/usr/bin/true` (exit 0); preflight returns .blocked so we stop early
        // without needing wrangler.
        let cmd = DeployCommand(
            resolveCommand: { _ in .unavailable(reason: "no wrangler in test") },
            resolveBuildCommand: { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) },
            tokenSource: { "token" },
            preflight: { _ in .blocked(failures: [], warnings: []) }
        )
        _ = await cmd.deploy(siteID: "s", siteDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                             onProgress: { recorder.record($0) })
        let phases = recorder.phases()
        #expect(phases.prefix(2) == ["building", "preflightScan"])
    }
}

/// Collects `OperationProgress` from the synchronous `ProgressHandler` sink. The handler is
/// `@Sendable (OperationProgress) -> Void` and runs inline inside the emitting actor's isolation,
/// so it can't `await` — which rules out making this an actor (that would force `Task { await
/// record(...) }`, and `Task` ordering is non-deterministic, breaking the phase-order assertions).
/// A plain lock is the right tool for a synchronous concurrent sink; `record`/`phases` have no
/// suspension points, so neither is `async`.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OperationProgress] = []
    func record(_ p: OperationProgress) { lock.lock(); items.append(p); lock.unlock() }
    func phases() -> [String] { lock.lock(); defer { lock.unlock() }; return items.map(\.phase) }
}
