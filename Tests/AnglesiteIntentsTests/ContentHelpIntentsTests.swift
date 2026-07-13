import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Covers the site-folder-unavailable guard shared by all three content-help intents (#465).
/// The success paths call the real `CopyEditAuditorFactory`/`SocialMediaPlannerFactory`/
/// `PostRepurposerFactory` (no test-only override exists for any of them yet, unlike
/// `DomainOperationsOverride` et al.), so they aren't exercised here.
extension AppIntentsTests {
    @Suite("ContentHelpIntents")
    struct ContentHelpIntentsTests {
        private func entity(directory: URL? = nil) -> SiteEntity {
            SiteEntity(id: "s1", name: "Portfolio", creationDate: nil, modificationDate: nil, directory: directory)
        }

        @Test("ReviewCopyIntent reports a missing site folder instead of crashing")
        func reviewCopyReportsMissingSiteFolder() async throws {
            var intent = ReviewCopyIntent()
            intent.site = entity(directory: nil)

            let dialog = try await intent.performForTesting()

            #expect(dialog.contains("site folder unavailable"))
            #expect(dialog.contains("Portfolio"))
        }

        @Test("PlanSocialMediaIntent reports a missing site folder instead of crashing")
        func planSocialMediaReportsMissingSiteFolder() async throws {
            var intent = PlanSocialMediaIntent()
            intent.site = entity(directory: nil)
            intent.weeks = 4

            let dialog = try await intent.performForTesting()

            #expect(dialog.contains("site folder unavailable"))
            #expect(dialog.contains("Portfolio"))
        }

        @Test("RepurposePostIntent reports a missing site folder instead of crashing, with an empty value")
        func repurposePostReportsMissingSiteFolder() async throws {
            var intent = RepurposePostIntent()
            intent.site = entity(directory: nil)
            intent.slug = "coast-trip"

            let (value, dialog) = try await intent.performForTesting()

            #expect(value.isEmpty)
            #expect(dialog.contains("site folder unavailable"))
            #expect(dialog.contains("Portfolio"))
        }
    }
}
