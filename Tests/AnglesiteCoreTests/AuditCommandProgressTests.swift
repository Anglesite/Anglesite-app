// Tests/AnglesiteCoreTests/AuditCommandProgressTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct AuditCommandProgressTests {
    @Test("emits building, one running-per-runner with fractions, then finalizing")
    func milestones() async {
        let recorder = ProgressRecorder()
        let r1 = PassRunner(category: .accessibility)
        let r2 = PassRunner(category: .seo)
        let cmd = AuditCommand(
            resolveBuildCommand: { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) },
            runners: [r1, r2]
        )
        _ = await cmd.audit(siteID: "s", siteDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                            onProgress: { recorder.record($0) })
        let phases = await recorder.phases()
        #expect(phases == ["building", "running", "running", "finalizing"])
    }
}

private struct PassRunner: AuditRunner {
    let category: AuditReport.Finding.Category
    func run(siteDirectory: URL, supervisor: ProcessSupervisor, logCenter: LogCenter, source: String) async throws -> [AuditReport.Finding] { [] }
}
