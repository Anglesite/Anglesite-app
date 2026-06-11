import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("BackupSiteIntent")
    struct BackupSiteIntentTests {
        @Test("succeeded result reports short SHA and remote")
        func succeededReportsShortSHAAndRemote() async throws {
            let (fake, site) = makeFakeAndSite()
            fake.backupResult = .succeeded(
                commitSHA: "abcdef1234567890",
                branch: "feature",
                remote: "git@example.com:me/site.git"
            )

            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = BackupSiteIntent()
                intent.site = SiteEntity(site)
                _ = try await intent.perform()
            }
            #expect(fake.backupCalls.count == 1)
        }

        @Test("noChanges resolves cleanly without surfacing a failure")
        func noChangesReportsCleanly() async throws {
            let (fake, site) = makeFakeAndSite()
            fake.backupResult = .noChanges

            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = BackupSiteIntent()
                intent.site = SiteEntity(site)
                _ = try await intent.perform()
            }
            #expect(fake.backupCalls.count == 1)
        }

        @Test("failure surfaces the reason")
        func failureSurfacesReason() async throws {
            let (fake, site) = makeFakeAndSite()
            fake.backupResult = .failed(reason: "push rejected", exitCode: 1)

            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = BackupSiteIntent()
                intent.site = SiteEntity(site)
                _ = try await intent.perform()
            }
            #expect(fake.backupCalls.count == 1)
        }

        private func makeFakeAndSite() -> (FakeOperations, SiteStore.Site) {
            let fake = FakeOperations()
            let site = TestStore.site(id: "s1", name: "Portfolio")
            fake.sites = [site.id: site]
            return (fake, site)
        }
    }
}
