import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("DesignInterviewIntents")
    @MainActor
    struct DesignInterviewIntentsTests {
        private func entity(_ siteID: String = AppIntentsTests.aSite, name: String = "Alpha") -> SiteEntity {
            SiteEntity(TestStore.site(id: siteID, name: name))
        }

        @Test("StartDesignInterviewIntent opens the site window and records a pending design-interview request")
        func startRequestsWindowAndInterview() async throws {
            WindowRouter.shared.requested = nil
            _ = WindowRouter.shared.consumeDesignInterviewRequest(for: AppIntentsTests.aSite)

            var intent = StartDesignInterviewIntent()
            intent.site = entity()
            _ = try await intent.perform()

            #expect(WindowRouter.shared.requested == AppIntentsTests.aSite)
            #expect(WindowRouter.shared.consumeDesignInterviewRequest(for: AppIntentsTests.aSite))
        }
    }
}
