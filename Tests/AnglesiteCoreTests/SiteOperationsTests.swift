import Testing
import Foundation
@testable import AnglesiteCore

/// `SiteOperations` core + dialog mapping. The command actors are faked through their existing
/// closure seams, so these tests verify the Result→dialog behavior without spawning anything.
struct SiteOperationsTests {

    /// A factory whose backup actor is scripted (via the git `runner` seam) to land on a
    /// clean feature branch → `.noChanges`. Deploy/audit aren't exercised here (their dialog
    /// mapping is tested directly against constructed `Result`s below).
    private struct FakeFactory: CommandFactory {
        func deploy() -> DeployCommand { DeployCommand() }
        func audit() -> AuditCommand { AuditCommand() }
        func backup() -> BackupCommand {
            BackupCommand(
                runner: { _, args in
                    switch args.first {
                    case "rev-parse":
                        // Serves both `--is-inside-work-tree` (exit 0 = repo) and
                        // `--abbrev-ref HEAD` (branch name → non-main so we proceed).
                        return .init(stdout: "feature\n", stderr: "", exitCode: 0)
                    case "remote":
                        return .init(stdout: "git@example.com:me/site.git\n", stderr: "", exitCode: 0)
                    case "status":
                        return .init(stdout: "", stderr: "", exitCode: 0) // clean → noChanges
                    default:
                        return .init(stdout: "", stderr: "unmocked git \(args.joined(separator: " "))", exitCode: 1)
                    }
                },
                streamer: { _, _, _ in (0, "") },
                clock: { Date(timeIntervalSince1970: 1_780_000_000) }
            )
        }
    }

    private func throwawayStore() -> SiteStore {
        SiteStore(persistenceURL: URL(fileURLWithPath: "/tmp/siteops-test-store.json"))
    }

    private func makeSite() -> SiteStore.Site {
        SiteStore.Site(
            id: "s1",
            name: "Portfolio",
            path: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            isValid: true,
            missingSentinels: []
        )
    }

    private func finding(_ severity: AuditReport.Finding.Severity) -> AuditReport.Finding {
        AuditReport.Finding(
            category: .seo, severity: severity, title: "t", detail: "d",
            remediation: nil, location: nil
        )
    }

    @Test("backup on a clean feature branch maps to a 'no changes' dialog")
    func backupNoChanges() async {
        let ops = SiteOperations(factory: FakeFactory(), store: throwawayStore())
        let result = await ops.backup(site: makeSite())
        #expect(result == .noChanges)
        #expect(SiteOperations.dialog(forBackup: result) == "No changes to back up.")
    }

    @Test("backup success dialog shows the short SHA and remote")
    func backupSuccessDialog() {
        let result = BackupCommand.Result.succeeded(
            commitSHA: "abcdef1234567890", branch: "feature", remote: "git@example.com:me/site.git"
        )
        #expect(SiteOperations.dialog(forBackup: result) == "Backed up abcdef1 to git@example.com:me/site.git.")
    }

    @Test("audit dialog summarizes findings by severity")
    func auditDialog() {
        let report = AuditReport(
            findings: [finding(.critical), finding(.warning), finding(.warning)],
            runnersExecuted: [.seo], runnersSkipped: []
        )
        let dialog = SiteOperations.dialog(forAudit: .succeeded(report: report, duration: 1))
        #expect(dialog == "Audit complete: 1 critical, 2 warning, 0 info.")
    }

    @Test("deploy success dialog shows the deployed URL")
    func deploySuccessDialog() {
        let url = URL(string: "https://portfolio.example.workers.dev")!
        #expect(
            SiteOperations.dialog(forDeploy: .succeeded(url: url, duration: 2))
                == "Deployed to https://portfolio.example.workers.dev."
        )
    }

    @Test("deploy blocked dialog reports the issue count and never offers an override")
    func deployBlockedDialog() {
        let failure = PreDeployCheck.ScanFailure(
            category: .exposedToken, file: "src/index.md", detail: "API key committed", remediation: "Remove it"
        )
        let dialog = SiteOperations.dialog(forDeploy: .blocked(failures: [failure], warnings: []))
        #expect(dialog == "Deploy blocked by the pre-deploy security scan (1 issue). Resolve these in Anglesite first.")
        #expect(!dialog.lowercased().contains("force"))
        #expect(!dialog.lowercased().contains("override"))
    }
}
