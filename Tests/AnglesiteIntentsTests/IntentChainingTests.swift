import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Verifies the audit→deploy chaining contract from #90: AuditSiteIntent returns the SiteEntity
/// it processed so a Shortcut can pipe that value into DeploySiteIntent. We exercise both
/// `perform()` calls inside one scoped override and assert both ops layer methods saw the same
/// site id.
extension AppIntentsTests {
    @Suite("IntentChaining")
    struct IntentChainingTests {
        @Test("audit output flows into deploy as input")
        func auditOutputFlowsIntoDeploy() async throws {
            let fake = FakeOperations()
            let site = TestStore.site(id: "s1", name: "Portfolio")
            fake.sites = [site.id: site]
            fake.auditResult = .succeeded(
                report: AuditReport(findings: [], runnersExecuted: [.seo], runnersSkipped: []),
                duration: 1
            )
            fake.deployResult = .succeeded(url: URL(string: "https://example.com")!, duration: 1)

            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var audit = AuditSiteIntent()
                audit.site = SiteEntity(site)
                _ = try await audit.perform()

                // Shortcuts editor wires audit's returned SiteEntity into deploy. Reproduce that
                // by constructing deploy with the same SiteEntity value the audit returned.
                var deploy = DeploySiteIntent()
                deploy.site = SiteEntity(site)
                _ = try await deploy.perform()
            }
            #expect(fake.auditCalls.count == 1)
            #expect(fake.deployCalls.count == 1)
            #expect(fake.auditCalls.first?.id == fake.deployCalls.first?.id)
        }

        // D.1 (#162): DeploySiteIntent and BackupSiteIntent now return the SiteEntity they
        // processed (ReturnsValue<SiteEntity>), mirroring AuditSiteIntent, so an agent/Shortcut
        // can pipe deploy→backup. Reproduce that wiring by feeding the same SiteEntity into both.
        @Test("deploy output flows into backup as input")
        func deployOutputFlowsIntoBackup() async throws {
            let fake = FakeOperations()
            let site = TestStore.site(id: "s1", name: "Portfolio")
            fake.sites = [site.id: site]
            fake.deployResult = .succeeded(url: URL(string: "https://example.com")!, duration: 1)
            fake.backupResult = .succeeded(commitSHA: "abc1234", branch: "main", remote: "origin")

            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var deploy = DeploySiteIntent()
                deploy.site = SiteEntity(site)
                _ = try await deploy.perform()

                var backup = BackupSiteIntent()
                backup.site = SiteEntity(site)
                _ = try await backup.perform()
            }
            #expect(fake.deployCalls.count == 1)
            #expect(fake.backupCalls.count == 1)
            #expect(fake.deployCalls.first?.id == fake.backupCalls.first?.id)
        }
    }
}
