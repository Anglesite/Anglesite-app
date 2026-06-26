import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Personal type render smoke")
struct PersonalTypeRenderSmokeTests {

    /// Repo-root-relative path to the committed template. `swift test` runs with CWD = package root.
    static var templateDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/Template", isDirectory: true)
    }

    /// True when the template can actually be built: a Node binary plus an installed Astro.
    static var buildable: Bool {
        guard E2EPrerequisites.locateNode() != nil else { return false }
        return FileManager.default.isReadableFile(
            atPath: templateDir.appendingPathComponent("node_modules/astro/astro.js").path)
    }

    @Test("seeded personal types build and render their mf2 classes",
          .enabled(if: PersonalTypeRenderSmokeTests.buildable))
    func rendersMicroformats() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dist = Self.templateDir.appendingPathComponent("dist", isDirectory: true)
        try? FileManager.default.removeItem(at: dist)
        defer { try? FileManager.default.removeItem(at: dist) }

        let result = try await ProcessSupervisor.shared.run(
            executable: node,
            arguments: ["node_modules/astro/astro.js", "build"],
            currentDirectoryURL: Self.templateDir)
        #expect(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")

        func html(_ rel: String) throws -> String {
            try String(contentsOf: dist.appendingPathComponent(rel), encoding: .utf8)
        }
        #expect(try html("notes/hello-note/index.html").contains("h-entry"))
        #expect(try html("notes/hello-note/index.html").contains("dt-published"))
        #expect(try html("articles/hello-article/index.html").contains("p-name"))
        #expect(try html("photos/hello-photo/index.html").contains("u-photo"))
        #expect(try html("albums/hello-album/index.html").contains("u-photo"))
        #expect(try html("bookmarks/hello-bookmark/index.html").contains("u-bookmark-of"))
        #expect(try html("replies/hello-reply/index.html").contains("u-in-reply-to"))
        #expect(try html("likes/hello-like/index.html").contains("u-like-of"))
    }
}
