import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Feeds render smoke")
struct FeedsRenderSmokeTests {

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

    @Test("collections emit RSS/Atom/JSON and a combined feed",
          .enabled(if: FeedsRenderSmokeTests.buildable))
    func rendersFeeds() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dist = Self.templateDir.appendingPathComponent("dist", isDirectory: true)
        try? FileManager.default.removeItem(at: dist)
        defer { try? FileManager.default.removeItem(at: dist) }

        let result = try await ProcessSupervisor.shared.run(
            executable: node,
            arguments: ["node_modules/astro/astro.js", "build"],
            currentDirectoryURL: Self.templateDir)
        try #require(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")

        func exists(_ rel: String) -> Bool {
            FileManager.default.fileExists(atPath: dist.appendingPathComponent(rel).path)
        }
        func text(_ rel: String) throws -> String {
            try String(contentsOf: dist.appendingPathComponent(rel), encoding: .utf8)
        }

        // Combined feeds at the root.
        #expect(exists("rss.xml"))
        #expect(exists("atom.xml"))
        #expect(exists("feed.json"))

        // Per-collection feeds for every collection, all three formats.
        for c in ["blog", "notes", "articles", "photos", "albums", "bookmarks", "replies", "likes"] {
            #expect(exists("\(c)/rss.xml"), "missing \(c)/rss.xml")
            #expect(exists("\(c)/atom.xml"), "missing \(c)/atom.xml")
            #expect(exists("\(c)/feed.json"), "missing \(c)/feed.json")
        }

        // The dynamic [collection] entry route still renders (feed routes don't shadow it).
        #expect(exists("notes/hello-note/index.html"))

        // Feeds carry absolute URLs from `site`.
        #expect(try text("feed.json").contains("https://example.com/"))
        #expect(try text("blog/rss.xml").contains("<rss"))

        // A title-less type (likes) still produces a non-empty title.
        let likesJson = try text("likes/feed.json")
        #expect(likesJson.contains("\"title\""))
        #expect(!likesJson.contains("\"title\": \"\""))
    }
}
