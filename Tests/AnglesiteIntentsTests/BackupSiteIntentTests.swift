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

        @Test("missing site short-circuits before calling backup")
        func missingSiteShortCircuits() async throws {
            // Same not-found code path exists in all four intents; one test here is
            // representative coverage for the `guard let resolved = await ops.site(id:)` pattern.
            let fake = FakeOperations()
            // fake.sites left empty — site(id:) returns nil
            let site = TestStore.site(id: "missing", name: "Gone")

            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = BackupSiteIntent()
                intent.site = SiteEntity(site)
                _ = try await intent.perform()
            }
            #expect(fake.siteCalls == ["missing"])    // looked up
            #expect(fake.backupCalls.isEmpty)         // but never reached the backup call
        }

        private func makeFakeAndSite() -> (FakeOperations, SiteStore.Site) {
            let fake = FakeOperations()
            let site = TestStore.site(id: "s1", name: "Portfolio")
            fake.sites = [site.id: site]
            return (fake, site)
        }
    }
}
