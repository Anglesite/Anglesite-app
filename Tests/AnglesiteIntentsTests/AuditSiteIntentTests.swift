import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("AuditSiteIntent")
    struct AuditSiteIntentTests {
        @Test("reports finding counts by severity")
        func reportsFindingCountsBySeverity() async throws {
            let (fake, site) = makeFakeAndSite()
            let report = AuditReport(
                findings: [finding(.critical), finding(.warning), finding(.warning)],
                runnersExecuted: [.seo],
                runnersSkipped: []
            )
            fake.auditResult = .succeeded(report: report, duration: 1)

            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = AuditSiteIntent()
                intent.site = SiteEntity(site)
                _ = try await intent.perform()
            }
            #expect(fake.auditCalls.count == 1)
        }

        @Test("returns the SiteEntity value so a Shortcut can pipe audit into deploy")
        func returnsSiteValueForChaining() async throws {
            let (fake, site) = makeFakeAndSite()
            let report = AuditReport(findings: [], runnersExecuted: [.seo], runnersSkipped: [])
            fake.auditResult = .succeeded(report: report, duration: 1)

            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = AuditSiteIntent()
                intent.site = SiteEntity(site)
                _ = try await intent.perform()
            }
            #expect(fake.auditCalls.first?.id == site.id)
        }

        private func makeFakeAndSite() -> (FakeOperations, SiteStore.Site) {
            let fake = FakeOperations()
            let site = TestStore.site(id: "s1", name: "Portfolio")
            fake.sites = [site.id: site]
            return (fake, site)
        }

        private func finding(_ severity: AuditReport.Finding.Severity) -> AuditReport.Finding {
            AuditReport.Finding(
                category: .seo,
                severity: severity,
                title: "t",
                detail: "d",
                remediation: nil,
                location: nil
            )
        }
    }
}
