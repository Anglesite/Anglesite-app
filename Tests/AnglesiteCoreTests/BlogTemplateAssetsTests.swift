// Tests/AnglesiteCoreTests/BlogTemplateAssetsTests.swift
// Hermetic test — no app bundle or TemplateRuntime needed. Resolves the template
// by walking up from #filePath (Tests/AnglesiteCoreTests/ -> Tests/ -> repo root).
// Classic URL APIs only (see IntegrationTemplateAssetsTests / PR #283 CI notes).
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct BlogTemplateAssetsTests {

    private func templateRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path), "repo-root detection drifted")
        return repoRoot.appendingPathComponent("Resources/Template")
    }

    @Test func contentConfigDefinesBlogCollection() throws {
        let root = templateRoot()
        let cfg = root.appendingPathComponent("src/content.config.ts")
        #expect(FileManager.default.fileExists(atPath: cfg.path), "missing src/content.config.ts")
        let s = try String(contentsOf: cfg, encoding: .utf8)
        #expect(s.contains("defineCollection"))
        #expect(s.contains("glob("))
        // V-1.2 (#344) expanded the export to { blog, notes, articles, … }; blog must remain registered.
        #expect(s.range(of: #"collections = \{[^}]*\bblog\b[^}]*\}"#, options: .regularExpression) != nil,
                "blog must remain in the collections export")
        // minimal schema fields
        for field in ["title:", "pubDate:", "description:", "draft:"] {
            #expect(s.contains(field), "schema missing \(field)")
        }
    }

    @Test func starterPostExistsWithRequiredFrontmatter() throws {
        let root = templateRoot()
        let post = root.appendingPathComponent("src/content/blog/welcome-to-your-blog.md")
        #expect(FileManager.default.fileExists(atPath: post.path), "missing starter post")
        let s = try String(contentsOf: post, encoding: .utf8)
        #expect(s.hasPrefix("---"), "post must start with frontmatter")
        #expect(s.contains("title:"))
        #expect(s.contains("pubDate:"))
    }

    @Test func postRouteRendersThroughBlogPostLayout() throws {
        let root = templateRoot()
        let route = root.appendingPathComponent("src/pages/blog/[...slug].astro")
        #expect(FileManager.default.fileExists(atPath: route.path), "missing post route")
        let s = try String(contentsOf: route, encoding: .utf8)
        // renders through BlogPost (the giscus host layout)
        #expect(s.contains("import BlogPost from \"../../layouts/BlogPost.astro\""))
        #expect(s.contains("getStaticPaths"))
        #expect(s.contains("getCollection(\"blog\""))
        // drafts excluded from the generated paths
        #expect(s.contains("!data.draft"))
        // post body rendered into the layout slot
        #expect(s.contains("<Content />"))
        #expect(s.contains("<BlogPost"))
        // pubDate forwarded so the layout can display the publication date
        #expect(s.contains("pubDate={post.data.pubDate}"))
    }

    @Test func blogPostLayoutRendersTitleAndDate() throws {
        let root = templateRoot()
        let s = try String(contentsOf: root.appendingPathComponent("src/layouts/BlogPost.astro"), encoding: .utf8)
        // visible heading + publication date in the article body
        #expect(s.contains("<h1>{title}</h1>"), "post should render its title as an <h1>")
        #expect(s.contains("pubDate"), "layout should accept/render pubDate")
        #expect(s.contains("<time"), "date should use a semantic <time> element")
        // render the date in UTC so a build machine behind UTC doesn't shift it a day
        #expect(s.contains("timeZone: \"UTC\""), "date must render in UTC to match the datetime attribute")
        // the giscus import anchor must survive any layout edits (descriptor injects here)
        #expect(s.contains("// anglesite:imports"), "imports anchor must remain for giscus injection")
    }

    @Test func blogIndexListsCollection() throws {
        let root = templateRoot()
        let index = root.appendingPathComponent("src/pages/blog/index.astro")
        #expect(FileManager.default.fileExists(atPath: index.path), "missing blog index")
        let s = try String(contentsOf: index, encoding: .utf8)
        #expect(s.contains("import BaseLayout from \"../../layouts/BaseLayout.astro\""))
        #expect(s.contains("getCollection(\"blog\""))
        #expect(s.contains("/blog/"))
        #expect(s.contains("!data.draft"))   // drafts filtered from the listing
        // each entry shows its publication date in a semantic <time> element
        #expect(s.contains("<time"))
        #expect(s.contains("pubDate"))
    }

    @Test func homepageLinksToBlog() throws {
        let root = templateRoot()
        let s = try String(contentsOf: root.appendingPathComponent("src/pages/index.astro"), encoding: .utf8)
        #expect(s.contains("href=\"/blog/\""), "homepage should link to /blog/")
    }

    @Test func giscusInjectsIntoBodyNotFrontmatter() throws {
        // MarkerInjector matches the FIRST occurrence of the anchor. If the anchor text
        // also appears in BlogPost.astro's frontmatter doc-comment, giscus injects into
        // the frontmatter and never renders. Guard the real layout against that regression.
        let root = templateRoot()
        let src = try String(contentsOf: root.appendingPathComponent("src/layouts/BlogPost.astro"), encoding: .utf8)
        let out = try MarkerInjector.inject(
            snippet: "<Comments />", withID: "comments",
            atAnchor: "<!-- anglesite:comments -->", into: src, style: .html).get()
        let frontmatterClose = out.range(of: "\n---\n")  // closing fence of Astro frontmatter
        let injected = out.range(of: "<Comments />")
        #expect(frontmatterClose != nil, "BlogPost.astro should have an Astro frontmatter fence")
        #expect(injected != nil, "injected giscus snippet should be present")
        #expect(injected!.lowerBound > frontmatterClose!.upperBound,
                "giscus must inject into the <article> body, not the frontmatter — a duplicate anchor in a frontmatter comment makes the first-match injector target the wrong spot")
    }
}
