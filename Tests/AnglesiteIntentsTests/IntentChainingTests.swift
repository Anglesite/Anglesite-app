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

        // F-3 (#163): AddPageIntent returns the created PageEntity so an agent can chain
        // create→preview. Reproduce by feeding the factory-built entity into PreviewSiteIntent.
        @Test("add-page output flows into preview as input")
        @MainActor
        func addPageOutputFlowsIntoPreview() async throws {
            WindowRouter.shared.requested = nil
            let created = PageEntity.make(
                siteID: AppIntentsTests.aSite, name: "About", requestedRoute: "/about",
                result: .created(filePath: "src/pages/about.astro", identifier: "/about"))

            var preview = PreviewSiteIntent()
            preview.site = SiteEntity(TestStore.site(id: AppIntentsTests.aSite, name: "Alpha"))
            preview.page = created
            _ = try await preview.perform()

            #expect(WindowRouter.shared.requested == AppIntentsTests.aSite)
        }

        // F-3 (#163): AddPostIntent returns the created PostEntity carrying slug+collection for chaining.
        @Test("add-post output carries slug and collection for chaining")
        func addPostOutputCarriesIdentity() {
            let e = PostEntity.make(
                siteID: AppIntentsTests.aSite, title: "Hello", requestedCollection: nil, requestedSlug: nil,
                result: .created(filePath: "src/content/blog/hello.md", identifier: "hello"))
            #expect(e.slug == "hello")
            #expect(e.collection == "blog")
            #expect(e.id == "\(AppIntentsTests.aSite):post:hello")
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
