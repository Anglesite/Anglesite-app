import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `AuditCommand` — the deterministic structured-audit path that replaces
/// the chat-routed `/anglesite:check` pill for one-click audits (#86).
///
/// The actor owns a build step + a list of pluggable `AuditRunner`s. Tests use a
/// `FakeAuditRunner` to script `[Finding]` results without spawning `tsx`. The
/// `JSONAuditRunnerTests` cover the parser separately so `AuditCommand` only has to
/// know about runner success/failure, not the audit script's JSON shape.
struct AuditCommandTests {

    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    private func makeCommand(
        runners: [any AuditRunner],
        build: @escaping AuditCommand.CommandResolver = { _ in
            .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        }
    ) -> (AuditCommand, ProcessSupervisor, LogCenter) {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let cmd = AuditCommand(
            supervisor: supervisor,
            logCenter: center,
            resolveBuildCommand: build,
            runners: runners
        )
        return (cmd, supervisor, center)
    }

    private func shFixture(_ script: String) -> AuditCommand.LaunchPlan {
        .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    }

    // MARK: Build failure

    @Test("Fails when the build step exits non-zero")
    func failsWhenBuildExitsNonZero() async {
        let (cmd, _, _) = makeCommand(
            runners: [FakeAuditRunner(category: .accessibility, result: .success([]))],
            build: { _ in self.shFixture("exit 1") }
        )
        let result = await cmd.audit(siteID: "site", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.lowercased().contains("build"), "reason should name the failing step: \(reason)")
        #expect(exit == 1)
    }

    @Test("Fails when the build resolver reports unavailable")
    func failsWhenBuildResolverReportsUnavailable() async {
        let (cmd, _, _) = makeCommand(
            runners: [FakeAuditRunner(category: .accessibility, result: .success([]))],
            build: { _ in .unavailable(reason: "vendored npm not found — rebuild the app") }
        )
        let result = await cmd.audit(siteID: "site", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason == "vendored npm not found — rebuild the app")
        #expect(exit == nil)
    }

    // MARK: Empty runner list

    @Test("Empty runners list returns a success with no findings")
    func emptyRunnersListReturnsSuccessWithNoFindings() async {
        let (cmd, _, _) = makeCommand(runners: [])
        let result = await cmd.audit(siteID: "site", siteDirectory: tmpDir)
        guard case .succeeded(let report, _) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(report.findings.isEmpty)
        #expect(report.runnersExecuted.isEmpty)
        #expect(report.runnersSkipped.isEmpty)
    }

    // MARK: Happy path — single runner

    @Test("Single accessibility runner: findings are returned and category is recorded")
    func singleAccessibilityRunnerSucceeds() async {
        let finding = AuditReport.Finding(
            category: .accessibility,
            severity: .critical,
            title: "Missing alt text",
            detail: "<img> on /about/ has no alt attribute",
            remediation: "Add a one-sentence description",
            location: "src/pages/about.astro"
        )
        let (cmd, _, _) = makeCommand(
            runners: [FakeAuditRunner(category: .accessibility, result: .success([finding]))]
        )
        let result = await cmd.audit(siteID: "site", siteDirectory: tmpDir)
        guard case .succeeded(let report, _) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(report.findings == [finding])
        #expect(report.runnersExecuted == [.accessibility])
        #expect(report.runnersSkipped.isEmpty)
    }

    // MARK: Runner failure → skipped, not fatal

    @Test("A runner that throws is recorded as skipped — the audit still succeeds")
    func runnerThatThrowsIsRecordedAsSkipped() async {
        struct BoomError: Error { var localizedDescription: String { "a11y tooling missing" } }
        let accessibilityFinding = AuditReport.Finding(
            category: .accessibility, severity: .info, title: "fine", detail: "", remediation: nil, location: nil
        )
        let (cmd, _, _) = makeCommand(runners: [
            FakeAuditRunner(category: .accessibility, result: .success([accessibilityFinding])),
            FakeAuditRunner(category: .performance, result: .failure(BoomError()))
        ])
        let result = await cmd.audit(siteID: "site", siteDirectory: tmpDir)
        guard case .succeeded(let report, _) = result else {
            Issue.record("expected .succeeded (runner failures are not fatal), got \(result)")
            return
        }
        #expect(report.findings == [accessibilityFinding])
        #expect(report.runnersExecuted == [.accessibility])
        #expect(report.runnersSkipped.count == 1)
        #expect(report.runnersSkipped.first?.category == .performance)
    }

    // MARK: Multiple runners — order preserved

    @Test("Findings from multiple runners are concatenated in runner order")
    func findingsFromMultipleRunnersAreConcatenated() async {
        let a = AuditReport.Finding(category: .accessibility, severity: .critical, title: "a", detail: "", remediation: nil, location: nil)
        let s = AuditReport.Finding(category: .seo, severity: .warning, title: "s", detail: "", remediation: nil, location: nil)
        let p = AuditReport.Finding(category: .performance, severity: .info, title: "p", detail: "", remediation: nil, location: nil)
        let (cmd, _, _) = makeCommand(runners: [
            FakeAuditRunner(category: .accessibility, result: .success([a])),
            FakeAuditRunner(category: .seo, result: .success([s])),
            FakeAuditRunner(category: .performance, result: .success([p]))
        ])
        let result = await cmd.audit(siteID: "site", siteDirectory: tmpDir)
        guard case .succeeded(let report, _) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(report.findings == [a, s, p])
        #expect(report.runnersExecuted == [.accessibility, .seo, .performance])
    }
}

// MARK: - Fake runner

private struct FakeAuditRunner: AuditRunner {
    let category: AuditReport.Finding.Category
    let result: Result<[AuditReport.Finding], Error>

    func run(siteDirectory: URL, supervisor: ProcessSupervisor, logCenter: LogCenter, source: String) async throws -> [AuditReport.Finding] {
        switch result {
        case .success(let findings): return findings
        case .failure(let error):    throw error
        }
    }
}
