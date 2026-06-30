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
        func socialWorkerProvision() -> SocialWorkerProvisionCommand {
            SocialWorkerProvisionCommand(tokenSource: { nil })
        }
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
            packageURL: URL(fileURLWithPath: NSTemporaryDirectory() + "portfolio.anglesite", isDirectory: true),
            isValid: true,
            missingSentinels: []
        )
    }

    private func makeSite(name: String, packageURL: URL) -> SiteStore.Site {
        SiteStore.Site(
            id: "s1",
            name: name,
            packageURL: packageURL,
            isValid: true,
            missingSentinels: []
        )
    }

    private func temporaryPackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteOperationsTests-\(UUID().uuidString).anglesite", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("Source", isDirectory: true),
            withIntermediateDirectories: true
        )
        return package
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

    @Test("deploy failure dialog surfaces the reason")
    func deployFailureDialog() {
        let dialog = SiteOperations.dialog(forDeploy: .failed(reason: "network down", exitCode: 1))
        #expect(dialog == "Deploy failed: network down")
    }

    @Test("social Worker provisioning runs through SiteOperations and slugifies the worker name")
    func socialWorkerProvisionOperation() async throws {
        let package = try temporaryPackage()
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let recorder = SocialWorkerRecorder()
        let ops = SiteOperations(factory: SocialWorkerFactory(recorder: recorder), store: throwawayStore())

        let result = await ops.provisionSocialWorker(site: site)

        guard case .succeeded(let url, _, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(url == URL(string: "https://blue-bottle-cafe.example.workers.dev"))
        #expect(await recorder.arguments == [
            ["d1", "create", "blue-bottle-cafe-social", "--json"],
            ["kv", "namespace", "create", "blue-bottle-cafe-social", "--json"],
        ])
        #expect(await recorder.deployCalls == [
            .init(token: "token", siteID: "s1", siteDirectory: package.appendingPathComponent("Source", isDirectory: true))
        ])
    }

    @Test("social Worker provisioning dialog reports success and resources")
    func socialWorkerProvisionSuccessDialog() {
        let result = SocialWorkerProvisionCommand.Result.succeeded(
            url: URL(string: "https://site.example.workers.dev")!,
            resources: .init(d1DatabaseID: "d1", kvNamespaceID: "kv"),
            duration: 1
        )
        #expect(
            SiteOperations.dialog(forSocialWorkerProvision: result)
                == "Social Worker provisioned at https://site.example.workers.dev. Provisioned resources: D1, KV."
        )
    }

    @Test("social Worker provisioning blocked dialog preserves security gate wording")
    func socialWorkerProvisionBlockedDialog() {
        let failure = PreDeployCheck.ScanFailure(
            category: .exposedToken,
            file: "dist/index.html",
            detail: "API key committed",
            remediation: "Remove it"
        )
        let result = SocialWorkerProvisionCommand.Result.blocked(
            failures: [failure],
            warnings: [],
            resources: .init(d1DatabaseID: "d1", kvNamespaceID: "kv", r2BucketName: "media")
        )
        let dialog = SiteOperations.dialog(forSocialWorkerProvision: result)
        #expect(dialog == "Social Worker provisioning blocked by the pre-deploy security scan (1 issue). Provisioned resources: D1, KV, R2.")
        #expect(!dialog.lowercased().contains("force"))
        #expect(!dialog.lowercased().contains("override"))
    }

    @Test("social Worker provisioning failure dialog includes partial resources")
    func socialWorkerProvisionFailureDialog() {
        let result = SocialWorkerProvisionCommand.Result.failed(
            reason: "KV failed",
            exitCode: 1,
            resources: .init(d1DatabaseID: "d1")
        )
        #expect(
            SiteOperations.dialog(forSocialWorkerProvision: result)
                == "Social Worker provisioning failed: KV failed. Provisioned resources: D1."
        )
    }

    @Test("backup failure dialog surfaces the reason")
    func backupFailureDialog() {
        let dialog = SiteOperations.dialog(forBackup: .failed(reason: "push rejected", exitCode: 1))
        #expect(dialog == "Backup failed: push rejected")
    }

    @Test("audit failure dialog surfaces the reason")
    func auditFailureDialog() {
        let dialog = SiteOperations.dialog(forAudit: .failed(reason: "config missing", exitCode: 1, logTail: []))
        #expect(dialog == "Audit failed: config missing")
    }
}

private actor SocialWorkerRecorder {
    private var seenArguments: [[String]] = []
    private var seenDeployCalls: [DeployCall] = []

    var arguments: [[String]] { seenArguments }
    var deployCalls: [DeployCall] { seenDeployCalls }

    func run(arguments: [String]) -> ProcessSupervisor.RunResult {
        seenArguments.append(arguments)
        switch arguments.first {
        case "d1":
            return .init(stdout: #"{"uuid":"d1-id"}"#, stderr: "", exitCode: 0)
        case "kv":
            return .init(stdout: #"{"id":"kv-id"}"#, stderr: "", exitCode: 0)
        default:
            return .init(stdout: "unexpected arguments \(arguments)", stderr: "", exitCode: 127)
        }
    }

    func deploy(token: String, siteID: String, siteDirectory: URL) -> DeployCommand.Result {
        seenDeployCalls.append(.init(token: token, siteID: siteID, siteDirectory: siteDirectory))
        return .succeeded(url: URL(string: "https://blue-bottle-cafe.example.workers.dev")!, duration: 1)
    }
}

private struct DeployCall: Sendable, Equatable {
    let token: String
    let siteID: String
    let siteDirectory: URL
}

private struct SocialWorkerFactory: CommandFactory {
    let recorder: SocialWorkerRecorder

    func deploy() -> DeployCommand { DeployCommand() }
    func backup() -> BackupCommand { BackupCommand(runner: { _, _ in .init(stdout: "", stderr: "", exitCode: 1) }, streamer: { _, _, _ in (1, "") }) }
    func audit() -> AuditCommand { AuditCommand(resolveBuildCommand: { _ in .unavailable(reason: "noop") }, runners: []) }
    func socialWorkerProvision() -> SocialWorkerProvisionCommand {
        SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            runner: { _, arguments, _, _ in await recorder.run(arguments: arguments) },
            deployer: { token, siteID, siteDirectory in await recorder.deploy(token: token, siteID: siteID, siteDirectory: siteDirectory) }
        )
    }
}
