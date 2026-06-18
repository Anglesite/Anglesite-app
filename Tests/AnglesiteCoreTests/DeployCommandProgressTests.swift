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
        let phases = await recorder.phases()
        #expect(phases.prefix(2) == ["building", "preflightScan"])
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OperationProgress] = []
    func record(_ p: OperationProgress) { lock.lock(); items.append(p); lock.unlock() }
    func phases() async -> [String] { lock.lock(); defer { lock.unlock() }; return items.map(\.phase) }
}
