import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SocialPublishPlan")
struct SocialPublishPlanTests {
    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("social-plan-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("collects webmention targets from mf2 frontmatter and body links")
    func webmentionTargets() throws {
        let root = makeSite([
            "src/content/replies/hello.md": """
            ---
            slug: reply-to-someone
            inReplyTo: "https://example.com/post"
            publishDate: 2026-06-29
            ---
            Body links to https://elsewhere.test/page, and repeats https://example.com/post.
            Internal links like https://mysite.test/about are not webmention targets.
            """
        ])

        let plan = try SocialPublishPlan.build(
            projectRoot: root,
            siteBase: URL(string: "https://mysite.test")!
        )

        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].sourceFile == "src/content/replies/hello.md")
        #expect(plan.entries[0].canonicalURL.absoluteString == "https://mysite.test/replies/reply-to-someone/")
        #expect(plan.entries[0].webmentionTargets.map(\.absoluteString) == [
            "https://elsewhere.test/page",
            "https://example.com/post",
        ])
    }

    @Test("collects requested POSSE destinations without requiring outbound links")
    func posseTargets() throws {
        let root = makeSite([
            "src/content/notes/today.md": """
            ---
            publishDate: 2026-06-29
            posse: [mastodon, bluesky, mastodon]
            ---
            Short note.
            """
        ])

        let plan = try SocialPublishPlan.build(
            projectRoot: root,
            siteBase: URL(string: "https://mysite.test/")!
        )

        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].canonicalURL.absoluteString == "https://mysite.test/notes/today/")
        #expect(plan.entries[0].webmentionTargets.isEmpty)
        #expect(plan.entries[0].posseTargets == ["bluesky", "mastodon"])
        #expect(plan.posseCount == 2)
    }

    @Test("skips drafts and entries with no outbound social work")
    func skipsNonPublishableEntries() throws {
        let root = makeSite([
            "src/content/notes/draft.md": """
            ---
            draft: true
            inReplyTo: "https://example.com/post"
            ---
            Draft.
            """,
            "src/content/notes/local.md": """
            ---
            publishDate: 2026-06-29
            ---
            Only links to https://mysite.test/elsewhere.
            """
        ])

        let plan = try SocialPublishPlan.build(
            projectRoot: root,
            siteBase: URL(string: "https://mysite.test")!
        )

        #expect(plan.isEmpty)
        #expect(plan.webmentionCount == 0)
    }
}
