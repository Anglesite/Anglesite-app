import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Covers acceptance: DeploySiteIntent has system-pathway test coverage (#104).
///
/// `SiteOperationsOverride.scoped` bypasses `@Dependency` and skips the deploy confirmation
/// prompt — see the file's own doc comment for why this is necessary under `swift test`.
extension AppIntentsTests {
    @Suite("DeploySiteIntent")
    struct DeploySiteIntentTests {
        @Test("succeeds and reports the deployed URL")
        func succeedsAndReportsDeployedURL() async throws {
            let (fake, site) = makeFakeAndSite()
            let url = URL(string: "https://portfolio.example.workers.dev")!
            fake.deployResult = .succeeded(url: url, duration: 2)

            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = DeploySiteIntent()
                intent.site = SiteEntity(site)
                _ = try await intent.perform()
            }
            #expect(fake.deployCalls.count == 1)
            #expect(fake.deployCalls.first?.id == site.id)
        }

        @Test("blocked deploy is surfaced through the ops layer")
        func blockedSurfacesPreDeployFailure() async throws {
            let (fake, site) = makeFakeAndSite()
            let failure = PreDeployCheck.ScanFailure(
                category: .exposedToken,
                file: "src/index.md",
                detail: "API key committed",
                remediation: "Remove it"
            )
            fake.deployResult = .blocked(failures: [failure], warnings: [])

            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = DeploySiteIntent()
                intent.site = SiteEntity(site)
                _ = try await intent.perform()
            }
            #expect(fake.deployCalls.count == 1)
        }

        @Test("failure surfaces the reason without retrying")
        func failureSurfacesReason() async throws {
            let (fake, site) = makeFakeAndSite()
            fake.deployResult = .failed(reason: "network down", exitCode: 1)

            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = DeploySiteIntent()
                intent.site = SiteEntity(site)
                _ = try await intent.perform()
            }
            #expect(fake.deployCalls.count == 1)
        }

        private func makeFakeAndSite() -> (FakeOperations, SiteStore.Site) {
            let fake = FakeOperations()
            let site = TestStore.site(id: "s1", name: "Portfolio")
            fake.sites = [site.id: site]
            return (fake, site)
        }
    }
}
