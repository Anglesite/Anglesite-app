import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Records calls and vends configurable Results. Each test sets up the result it expects and
/// reads back call records after the intent runs.
///
/// Class (not struct) so the override-scoped reference semantics let every test see the same
/// mutated instance — the intent's `SiteOperationsOverride.scoped ?? self.ops` reads the
/// captured `fake` instance directly rather than a copy.
///
/// Thread-safety: `@unchecked Sendable` is safe only because each test uses its own instance
/// scoped to a single Task (via `SiteOperationsOverride.$scoped.withValue`) and the root
/// `@Suite("AppIntents", .serialized)` prevents inter-suite parallel access. Sharing a
/// single `FakeOperations` across concurrent tasks would race silently — don't.
final class FakeOperations: SiteOperationsService, @unchecked Sendable {
    var sites: [String: SiteStore.Site] = [:]
    var deployResult: DeployCommand.Result = .failed(reason: "unstubbed deploy", exitCode: nil)
    var backupResult: BackupCommand.Result = .failed(reason: "unstubbed backup", exitCode: nil)
    var auditResult: AuditCommand.Result = .failed(reason: "unstubbed audit", exitCode: nil, logTail: [])
    var socialWorkerProvisionResult: SocialWorkerProvisionCommand.Result = .failed(reason: "unstubbed social Worker provisioning", exitCode: nil, resources: .init())

    private(set) var siteCalls: [String] = []
    private(set) var deployCalls: [SiteStore.Site] = []
    private(set) var backupCalls: [SiteStore.Site] = []
    private(set) var auditCalls: [SiteStore.Site] = []
    private(set) var socialWorkerProvisionCalls: [SiteStore.Site] = []
    private(set) var lastDeployProgress: ProgressHandler?
    private(set) var lastBackupProgress: ProgressHandler?
    private(set) var lastAuditProgress: ProgressHandler?

    func site(id: String) async -> SiteStore.Site? {
        siteCalls.append(id)
        return sites[id]
    }

    func deploy(site: SiteStore.Site, onProgress: ProgressHandler?) async -> DeployCommand.Result {
        deployCalls.append(site)
        lastDeployProgress = onProgress
        return deployResult
    }

    func backup(site: SiteStore.Site, onProgress: ProgressHandler?) async -> BackupCommand.Result {
        backupCalls.append(site)
        lastBackupProgress = onProgress
        return backupResult
    }

    func audit(site: SiteStore.Site, onProgress: ProgressHandler?) async -> AuditCommand.Result {
        auditCalls.append(site)
        lastAuditProgress = onProgress
        return auditResult
    }

    func provisionSocialWorker(site: SiteStore.Site) async -> SocialWorkerProvisionCommand.Result {
        socialWorkerProvisionCalls.append(site)
        return socialWorkerProvisionResult
    }
}
