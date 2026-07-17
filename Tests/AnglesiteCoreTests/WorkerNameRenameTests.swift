import Testing
import Foundation
@testable import AnglesiteCore

struct WorkerNameRenameTests {
    private func makeSiteDirectory(wranglerToml: String, siteConfig: String = "") -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! wranglerToml.write(to: dir.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)
        if !siteConfig.isEmpty {
            try! siteConfig.write(to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("Rewrites only the name line, leaving the rest of wrangler.toml untouched")
    func rewritesNameLineOnly() throws {
        let toml = """
        name = "old-name"
        compatibility_date = "2026-07-15"
        compatibility_flags = ["nodejs_compat"]

        [assets]
        directory = "dist"
        """
        let dir = makeSiteDirectory(wranglerToml: toml, siteConfig: "CF_PROJECT_NAME=old-name\nSITE_NAME=My Site\n")

        try WorkerNameRename.apply(newName: "new-name", siteDirectory: dir)

        let updatedToml = try String(contentsOf: dir.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(updatedToml.contains(#"name = "new-name""#))
        #expect(updatedToml.contains(#"compatibility_date = "2026-07-15""#))
        #expect(updatedToml.contains("[assets]"))
    }

    @Test("Updates CF_PROJECT_NAME in .site-config without disturbing other keys")
    func updatesSiteConfig() throws {
        let dir = makeSiteDirectory(
            wranglerToml: #"name = "old-name""#,
            siteConfig: "CF_PROJECT_NAME=old-name\nSITE_NAME=My Site\n"
        )

        try WorkerNameRename.apply(newName: "new-name", siteDirectory: dir)

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "new-name")
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "My Site")
    }

    @Test("Rejects an invalid name before touching any file")
    func rejectsInvalidName() throws {
        let dir = makeSiteDirectory(wranglerToml: #"name = "old-name""#, siteConfig: "CF_PROJECT_NAME=old-name\n")

        #expect(throws: WorkerNameRename.RenameError.invalidName("bad name!")) {
            try WorkerNameRename.apply(newName: "bad name!", siteDirectory: dir)
        }

        let toml = try String(contentsOf: dir.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains(#"name = "old-name""#), "wrangler.toml must be untouched on rejection")
    }

    @Test("Throws .wranglerConfigMissing when there's no wrangler.toml")
    func missingWranglerConfig() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(throws: WorkerNameRename.RenameError.wranglerConfigMissing) {
            try WorkerNameRename.apply(newName: "new-name", siteDirectory: dir)
        }
    }

    @Test("Throws .nameLineNotFound when wrangler.toml exists but has no name line (e.g. hand-edited)")
    func nameLineNotFound() throws {
        let toml = """
        compatibility_date = "2026-07-15"
        compatibility_flags = ["nodejs_compat"]

        [assets]
        directory = "dist"
        """
        let dir = makeSiteDirectory(wranglerToml: toml, siteConfig: "CF_PROJECT_NAME=old-name\n")

        #expect(throws: WorkerNameRename.RenameError.nameLineNotFound) {
            try WorkerNameRename.apply(newName: "new-name", siteDirectory: dir)
        }

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "old-name", ".site-config must be untouched when the name line can't be found")
    }
}
