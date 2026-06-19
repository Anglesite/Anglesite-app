import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("OpenSiteIntent")
    struct OpenSiteIntentTests {
        // OpenSiteIntent doesn't touch SiteOperations — no override needed. The intent's
        // only observable side effect is mutating `WindowRouter.shared.requested`.
        @Test("sets WindowRouter.shared.requested to the site id")
        @MainActor
        func setsWindowRouterRequestedToSiteID() async throws {
            WindowRouter.shared.requested = nil   // reset between runs
            let site = TestStore.site(id: "s1", name: "Portfolio")
            var intent = OpenSiteIntent()
            intent.target = SiteEntity(site)
            _ = try await intent.perform()
            #expect(WindowRouter.shared.requested == "s1")
        }

        @Test("SiteEntity maps id and directory from SiteStore.Site")
        func siteEntityMapping() async throws {
            let testPath = "/tmp/MyProject.anglesite"
            let site = TestStore.site(id: "site-uuid-123", name: "My Project", path: "/tmp/MyProject")
            let entity = SiteEntity(site)
            #expect(entity.id == "site-uuid-123")
            #expect(entity.directory == URL(fileURLWithPath: testPath, isDirectory: true))
        }
    }
}
