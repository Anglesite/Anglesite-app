// Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
// Hermetic test — no app bundle or TemplateRuntime needed.
// Resolves the template by walking up from #filePath:
//   .../Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
//   → deletingLastPathComponent x3 → repo root
//   → appending "Resources/Template"
import Testing
import Foundation

@Suite struct IntegrationTemplateAssetsTests {

    private func templateRoot() -> URL {
        let here = URL(filePath: #filePath)
        // here      = .../Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
        // parent[0] = .../Tests/AnglesiteCoreTests/
        // parent[1] = .../Tests/
        // parent[2] = repo root
        let repoRoot = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appending(path: "Resources/Template")
    }

    @Test func requiredAssetsExist() {
        let root = templateRoot()
        let paths = [
            "src/components/BookingWidget.astro",
            "src/components/DonationButton.astro",
            "src/components/Comments.astro",
            "src/pages/book.astro",
            "src/pages/donate.astro",
        ]
        for p in paths {
            #expect(
                FileManager.default.fileExists(atPath: root.appending(path: p).path(percentEncoded: false)),
                "missing \(p)"
            )
        }
    }

    @Test func layoutsHaveAnchors() throws {
        let root = templateRoot()
        let baseURL = root.appending(path: "src/layouts/BaseLayout.astro")
        let base = try String(contentsOf: baseURL, encoding: .utf8)
        #expect(base.contains("<!-- anglesite:body-end -->"))

        let blogURL = root.appending(path: "src/layouts/BlogPost.astro")
        let blog = try String(contentsOf: blogURL, encoding: .utf8)
        #expect(blog.contains("<!-- anglesite:comments -->"))
    }
}
