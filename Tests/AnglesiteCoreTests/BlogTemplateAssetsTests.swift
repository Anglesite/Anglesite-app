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
        #expect(s.contains("collections = { blog }"))
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
}
