import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SocialPublishPlan")
struct SocialPublishPlanTests {
    private let referenceDate = Date(timeIntervalSince1970: 1_782_777_600) // 2026-06-30T00:00:00Z

    private func makeSite(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("social-plan-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("collects webmention targets from mf2 frontmatter and body links")
    func webmentionTargets() throws {
        let root = try makeSite([
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
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try SocialPublishPlan.build(
            projectRoot: root,
            siteBase: URL(string: "https://mysite.test")!,
            referenceDate: referenceDate
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
        let root = try makeSite([
            "src/content/notes/today.md": """
            ---
            publishDate: 2026-06-29
            posse: [mastodon, bluesky, mastodon]
            ---
            Short note.
            """
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try SocialPublishPlan.build(
            projectRoot: root,
            siteBase: URL(string: "https://mysite.test/")!,
            referenceDate: referenceDate
        )

        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].canonicalURL.absoluteString == "https://mysite.test/notes/today/")
        #expect(plan.entries[0].webmentionTargets.isEmpty)
        #expect(plan.entries[0].posseTargets == ["mastodon", "bluesky"])
        #expect(plan.posseCount == 2)
    }

    @Test("skips drafts and entries with no outbound social work")
    func skipsNonPublishableEntries() throws {
        let root = try makeSite([
            "src/content/notes/draft.md": """
            ---
            draft: "yes"
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
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try SocialPublishPlan.build(
            projectRoot: root,
            siteBase: URL(string: "https://mysite.test")!,
            referenceDate: referenceDate
        )

        #expect(plan.isEmpty)
        #expect(plan.webmentionCount == 0)
    }

    @Test("nested content paths keep their collection-relative slug")
    func nestedContentPathSlug() throws {
        let root = try makeSite([
            "src/content/notes/2026/june/hello.md": """
            ---
            publishDate: 2026-06-29
            ---
            See https://example.com/nested.
            """
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try SocialPublishPlan.build(
            projectRoot: root,
            siteBase: URL(string: "https://mysite.test")!,
            referenceDate: referenceDate
        )

        #expect(plan.entries.first?.canonicalURL.absoluteString == "https://mysite.test/notes/2026/june/hello/")
    }

    @Test("body URL scan ignores unrelated frontmatter URLs")
    func ignoresUnrelatedFrontmatterURLs() throws {
        let root = try makeSite([
            "src/content/articles/photo-credit.md": """
            ---
            publishDate: 2026-06-29
            image: "https://cdn.example.test/photo.jpg"
            inReplyTo: "https://example.com/reply-target"
            ---
            Body links to https://elsewhere.test/body-link.
            """
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try SocialPublishPlan.build(
            projectRoot: root,
            siteBase: URL(string: "https://mysite.test")!,
            referenceDate: referenceDate
        )

        #expect(plan.entries.first?.webmentionTargets.map(\.absoluteString) == [
            "https://elsewhere.test/body-link",
            "https://example.com/reply-target",
        ])
    }

    @Test("skips future-dated content")
    func skipsFutureDatedContent() throws {
        let root = try makeSite([
            "src/content/notes/tomorrow.md": """
            ---
            publishDate: 2026-07-01
            inReplyTo: "https://example.com/future"
            ---
            Scheduled.
            """
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try SocialPublishPlan.build(
            projectRoot: root,
            siteBase: URL(string: "https://mysite.test")!,
            referenceDate: referenceDate
        )

        #expect(plan.isEmpty)
    }
}
