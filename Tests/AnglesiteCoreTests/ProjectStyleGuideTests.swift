import Foundation
import Testing
@testable import AnglesiteCore

@Suite("ProjectStyleGuide")
struct ProjectStyleGuideTests {
    @Test("infers frontmatter, headings, links, markdown, and components")
    func infersProjectConventions() async {
        let root = makeSite([
            "src/content/posts/welcome.md": """
            ---
            title: "Welcome"
            publishDate: 2026-01-02
            draft: false
            tags: [launch, notes]
            ---

            ## Launch Notes

            We're writing for you and your team.

            - First point
            - Second point

            [About](/about)

            <Callout />
            """,
            "src/content/posts/update.md": """
            ---
            title: "Update"
            publishDate: 2026-01-03
            draft: true
            tags: []
            ---

            ## Product Update

            You'll find more context here.

            - Another point
            """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let guide = await index.projectStyleGuide(siteID: "site")

        #expect(guide.sourceCount == 2)
        #expect(guide.rules.contains { $0.id == "frontmatter-posts" && $0.detail.contains("publishDate") })
        #expect(guide.rules.contains { $0.id == "heading-hierarchy" && $0.detail.contains("h2") })
        #expect(guide.rules.contains { $0.id == "bullet-marker" && $0.detail.contains("`-`") })
        #expect(guide.rules.contains { $0.id == "internal-links" && $0.detail.contains("root-relative") })
        #expect(guide.rules.contains { $0.id == "components" && $0.detail.contains("Callout") })
        #expect(guide.assistantInstructions?.contains("Project style guide inferred") == true)
    }

    @Test("empty content produces no assistant instructions")
    func emptyContent() {
        let guide = ProjectStyleGuide.infer(siteID: "site", documents: [])

        #expect(guide.isEmpty)
        #expect(guide.assistantInstructions == nil)
    }

    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-style-guide-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }
}
