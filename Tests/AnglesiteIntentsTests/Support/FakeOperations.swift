import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Records calls and vends configurable Results. Each test sets up the result it expects and
/// reads back call records after the intent runs.
///
/// Class (not struct) so `AppDependencyManager.shared.add(fakeOps)` lets every test reads see
/// the same mutated instance — the stored-instance form intentionally skips the closure path
/// that would otherwise allocate a fresh instance per access.
final class FakeOperations: SiteOperationsService, @unchecked Sendable {
    var sites: [String: SiteStore.Site] = [:]
    var deployResult: DeployCommand.Result = .failed(reason: "unstubbed deploy", exitCode: nil)
    var backupResult: BackupCommand.Result = .failed(reason: "unstubbed backup", exitCode: nil)
    var auditResult: AuditCommand.Result = .failed(reason: "unstubbed audit", exitCode: nil, logTail: [])

    private(set) var siteCalls: [String] = []
    private(set) var deployCalls: [SiteStore.Site] = []
    private(set) var backupCalls: [SiteStore.Site] = []
    private(set) var auditCalls: [SiteStore.Site] = []

    func site(id: String) async -> SiteStore.Site? {
        siteCalls.append(id)
        return sites[id]
    }

    func deploy(site: SiteStore.Site) async -> DeployCommand.Result {
        deployCalls.append(site)
        return deployResult
    }

    func backup(site: SiteStore.Site) async -> BackupCommand.Result {
        backupCalls.append(site)
        return backupResult
    }

    func audit(site: SiteStore.Site) async -> AuditCommand.Result {
        auditCalls.append(site)
        return auditResult
    }
}
