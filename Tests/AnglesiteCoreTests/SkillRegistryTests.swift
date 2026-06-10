import XCTest
@testable import AnglesiteCore

final class SkillRegistryTests: XCTestCase {

    // MARK: Parser

    func testParsesDoubleQuotedDescription() {
        let source = """
        ---
        name: deploy
        description: "Build, scan, and deploy"
        allowed-tools: Bash, Read, Write
        ---

        Body
        """
        let skill = SkillRegistry.parseSkillFrontmatter(source)
        XCTAssertEqual(skill?.name, "deploy")
        XCTAssertEqual(skill?.description, "Build, scan, and deploy")
    }

    func testParsesSingleQuotedDescription() {
        let source = """
        ---
        name: backup
        description: 'GitHub backup'
        ---
        """
        XCTAssertEqual(SkillRegistry.parseSkillFrontmatter(source)?.description, "GitHub backup")
    }

    func testParsesBareDescription() {
        let source = """
        ---
        name: check
        description: Health audit
        ---
        """
        XCTAssertEqual(SkillRegistry.parseSkillFrontmatter(source)?.description, "Health audit")
    }

    func testTolerantOfColonsInsideValues() {
        let source = """
        ---
        name: redirect
        description: "Run a 301 redirect: from old URL to new"
        ---
        """
        XCTAssertEqual(SkillRegistry.parseSkillFrontmatter(source)?.description, "Run a 301 redirect: from old URL to new")
    }

    func testReturnsNilWhenNoFrontmatter() {
        XCTAssertNil(SkillRegistry.parseSkillFrontmatter("just body text\n# heading\n"))
    }

    func testReturnsNilWhenNameMissing() {
        let source = """
        ---
        description: "no name here"
        ---
        """
        XCTAssertNil(SkillRegistry.parseSkillFrontmatter(source))
    }

    func testDescriptionIsNilWhenAbsent() {
        let source = """
        ---
        name: minimal
        ---
        """
        let skill = SkillRegistry.parseSkillFrontmatter(source)
        XCTAssertEqual(skill?.name, "minimal")
        XCTAssertNil(skill?.description)
    }

    func testIgnoresUnknownFrontmatterKeys() {
        let source = """
        ---
        name: deploy
        description: "real"
        allowed-tools: Bash(*)
        disable-model-invocation: true
        argument-hint: "[optional]"
        ---
        """
        let skill = SkillRegistry.parseSkillFrontmatter(source)
        XCTAssertEqual(skill?.name, "deploy")
        XCTAssertEqual(skill?.description, "real")
    }

    // MARK: Discovery

    func testDiscoverReadsAllSkillDirectoriesInOrder() throws {
        let root = try makeFixturePlugin([
            "skills/alpha/SKILL.md": "---\nname: alpha\ndescription: \"first\"\n---\n",
            "skills/beta/SKILL.md": "---\nname: beta\ndescription: \"second\"\n---\n",
            "skills/gamma/SKILL.md": "---\nname: gamma\ndescription: \"third\"\n---\n"
        ])
        let skills = SkillRegistry.discover(pluginDirectory: root)
        XCTAssertEqual(skills.map(\.name), ["alpha", "beta", "gamma"])
    }

    func testDiscoverSkipsDirectoriesWithoutSkillMd() throws {
        let root = try makeFixturePlugin([
            "skills/has-skill/SKILL.md": "---\nname: has-skill\n---\n",
            "skills/no-skill/README.md": "no frontmatter here"
        ])
        XCTAssertEqual(SkillRegistry.discover(pluginDirectory: root).map(\.name), ["has-skill"])
    }

    func testDiscoverSkipsMalformedFiles() throws {
        let root = try makeFixturePlugin([
            "skills/good/SKILL.md": "---\nname: good\n---\n",
            "skills/broken/SKILL.md": "no frontmatter, just text"
        ])
        XCTAssertEqual(SkillRegistry.discover(pluginDirectory: root).map(\.name), ["good"])
    }

    func testDiscoverReturnsEmptyWhenSkillsDirectoryMissing() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(SkillRegistry.discover(pluginDirectory: tmp), [])
    }

    func testQuickActionsFiltersAndOrdersByCuratedList() throws {
        let root = try makeFixturePlugin([
            "skills/check/SKILL.md": "---\nname: check\ndescription: \"audit\"\n---\n",
            "skills/import/SKILL.md": "---\nname: import\ndescription: \"import content\"\n---\n",
            "skills/something-else/SKILL.md": "---\nname: something-else\n---\n",
            "skills/deploy/SKILL.md": "---\nname: deploy\ndescription: \"deploy\"\n---\n",
            "skills/backup/SKILL.md": "---\nname: backup\ndescription: \"snapshot\"\n---\n"
        ])
        let quick = SkillRegistry.quickActions(in: root)
        // `deploy` is intentionally absent: the toolbar Deploy button invokes
        // DeployCommand directly (#84), so surfacing a redundant LLM-routed Deploy
        // pill in chat would just burn tokens for an action that already has a
        // structured entry point.
        XCTAssertEqual(quick.map(\.name), ["backup", "check", "import"],
                       "must be in curated order, must exclude non-curated skills, must exclude deploy")
        XCTAssertEqual(quick.first?.description, "snapshot")
    }

    func testQuickActionsExcludesDeployEvenWhenSkillExists() throws {
        // Regression guard for #84: even with a deploy/SKILL.md on disk, the chat
        // quick-actions must not surface it — the toolbar owns Deploy.
        let root = try makeFixturePlugin([
            "skills/deploy/SKILL.md": "---\nname: deploy\ndescription: \"deploy\"\n---\n",
            "skills/backup/SKILL.md": "---\nname: backup\ndescription: \"snapshot\"\n---\n"
        ])
        XCTAssertEqual(SkillRegistry.quickActions(in: root).map(\.name), ["backup"])
    }

    func testQuickActionsTolerantOfMissingCuratedSkills() throws {
        // A plugin that's missing some of the curated names just returns whatever it has.
        let root = try makeFixturePlugin([
            "skills/backup/SKILL.md": "---\nname: backup\n---\n",
            "skills/check/SKILL.md": "---\nname: check\n---\n"
        ])
        XCTAssertEqual(SkillRegistry.quickActions(in: root).map(\.name), ["backup", "check"])
    }

    // MARK: Test helpers

    private func makeFixturePlugin(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skill-registry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
}
