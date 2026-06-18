// Tests/AnglesiteCoreTests/AuditCommandCancellationTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct AuditCommandCancellationTests {
    @Test("cancelling after the first runner skips the remaining runners")
    func cancelBetweenRunners() async throws {
        let counter = RunCounter()
        let holder = AuditTaskHolder()
        let first = ClosureRunner(category: .accessibility) { await counter.bump(); await holder.cancel(); return [] }
        let second = ClosureRunner(category: .seo) { await counter.bump(); return [] }
        // resolveBuildCommand returns .unavailable so runBuild is skipped? No — .unavailable fails the
        // audit. Instead inject a build command that exits 0 immediately via `true`.
        let cmd = AuditCommand(
            resolveBuildCommand: { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) },
            runners: [first, second]
        )
        let task = Task { await cmd.audit(siteID: "s", siteDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) }
        await holder.hold(task)
        _ = await task.value
        #expect(await counter.value == 1)   // only the first runner ran
    }
}

private actor RunCounter { private(set) var value = 0; func bump() { value += 1 } }
private actor AuditTaskHolder {
    private var pending = false
    private var task: Task<AuditCommand.Result, Never>?
    func cancel() { pending = true; task?.cancel() }
    func hold(_ t: Task<AuditCommand.Result, Never>) { task = t; if pending { t.cancel() } }
}
private struct ClosureRunner: AuditRunner {
    let category: AuditReport.Finding.Category
    let body: @Sendable () async -> [AuditReport.Finding]
    func run(siteDirectory: URL, supervisor: ProcessSupervisor, logCenter: LogCenter, source: String) async throws -> [AuditReport.Finding] {
        await body()
    }
}
