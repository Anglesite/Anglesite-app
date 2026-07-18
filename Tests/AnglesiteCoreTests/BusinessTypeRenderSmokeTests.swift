import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Business type render smoke")
struct BusinessTypeRenderSmokeTests {

    static var templateDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/Template", isDirectory: true)
    }

    /// True when the template can actually be built: a Node binary plus an installed Astro.
    static var buildable: Bool { E2EPrerequisites.astroBuildable(templateDir: templateDir) }

    @Test("seeded business types build and render their mf2 classes",
          .enabled(if: BusinessTypeRenderSmokeTests.buildable))
    func rendersMicroformats() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dist = Self.templateDir.appendingPathComponent("dist", isDirectory: true)

        func html(_ rel: String) throws -> String {
            try String(contentsOf: dist.appendingPathComponent(rel), encoding: .utf8)
        }

        // Hold the shared template-build lock across build + assertions: other render-smoke
        // suites rm -rf dist around their own build and would race on the shared template tree.
        try await TemplateBuildSerializer.shared.serialize {
            try? FileManager.default.removeItem(at: dist)
            defer { try? FileManager.default.removeItem(at: dist) }

            let result = try await ProcessSupervisor.shared.run(
                executable: node,
                arguments: [E2EPrerequisites.astroCLIRelativePath, "build"],
                currentDirectoryURL: Self.templateDir)
            try #require(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")

            #expect(try html("announcements/hello-announcement/index.html").contains("h-entry"))
            let event = try html("events/hello-event/index.html")
            #expect(event.contains("h-event"))
            #expect(event.contains("dt-start"))
            let review = try html("reviews/hello-review/index.html")
            #expect(review.contains("h-review"))
            #expect(review.contains("p-rating"))
            #expect(review.contains("p-name")) // explicit review title, distinct from p-item
            #expect(review.contains("p-item"))
        }
    }
}
