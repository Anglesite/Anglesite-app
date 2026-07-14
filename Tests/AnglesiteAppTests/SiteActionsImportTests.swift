import Testing
import Foundation
import AnglesiteCore
import AnglesiteSiteModel
@testable import AnglesiteAppCore

@Suite("SiteActions import")
@MainActor
struct SiteActionsImportTests {
    actor ImportRecorder {
        private(set) var bootstrappedSource: URL?

        func recordBootstrap(_ sourceDirectory: URL) {
            bootstrappedSource = sourceDirectory
        }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-actions-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePlainSite(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for sentinel in ProjectValidator.requiredSentinels {
            let file = url.appendingPathComponent(sentinel)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        }
    }

    @Test("import bootstraps git in the copied Source before registering")
    func importBootstrapsSourceBeforeRegistering() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain-site", isDirectory: true)
        try makePlainSite(at: source)
        let dest = root.appendingPathComponent("Imported.anglesite", isDirectory: true)

        let recorder = ImportRecorder()
        var registeredPackage: AnglesitePackage?
        let site = try await SiteActions.importDirectory(
            source,
            toPackageAt: dest,
            displayName: "Imported",
            bootstrapGit: { sourceDirectory in
                await recorder.recordBootstrap(sourceDirectory)
                try FileManager.default.createDirectory(
                    at: sourceDirectory.appendingPathComponent(".git"),
                    withIntermediateDirectories: true
                )
            },
            register: { package in
                registeredPackage = package
                #expect(FileManager.default.fileExists(atPath: package.sourceURL.appendingPathComponent(".git").path))
                return SiteStore.Site(
                    id: "site-id",
                    name: "Imported",
                    packageURL: package.url,
                    isValid: true,
                    missingSentinels: []
                )
            }
        )

        #expect(site.id == "site-id")
        #expect(await recorder.bootstrappedSource == dest.appendingPathComponent("Source", isDirectory: true))
        #expect(registeredPackage?.url == dest)
    }

    @Test("import seeds gitignore before git bootstrap stages the copied Source")
    func importSeedsGitignoreBeforeBootstrap() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain-site", isDirectory: true)
        try makePlainSite(at: source)
        try "custom-cache/\n".write(to: source.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "SECRET=1\n".write(to: source.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("node_modules/@rollup/rollup-darwin-arm64"),
            withIntermediateDirectories: true
        )
        try "binary\n".write(
            to: source.appendingPathComponent("node_modules/@rollup/rollup-darwin-arm64/index.js"),
            atomically: true,
            encoding: .utf8
        )

        let dest = root.appendingPathComponent("Imported.anglesite", isDirectory: true)
        _ = try await SiteActions.importDirectory(
            source,
            toPackageAt: dest,
            displayName: "Imported",
            bootstrapGit: { sourceDirectory in
                let gitignore = try String(
                    contentsOf: sourceDirectory.appendingPathComponent(".gitignore"),
                    encoding: .utf8
                )
                #expect(gitignore.contains("custom-cache/"))
                #expect(gitignore.contains("node_modules/"))
                #expect(gitignore.contains("dist/"))
                #expect(gitignore.contains(".astro/"))
                #expect(gitignore.contains(".wrangler/"))
                #expect(gitignore.contains(".env*"))
            },
            register: { package in
                SiteStore.Site(
                    id: "site-id",
                    name: "Imported",
                    packageURL: package.url,
                    isValid: true,
                    missingSentinels: []
                )
            }
        )
    }

    @Test("import removes copied package when git bootstrap fails")
    func importCleansUpWhenBootstrapFails() async throws {
        struct Boom: Error {}

        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain-site", isDirectory: true)
        try makePlainSite(at: source)
        let dest = root.appendingPathComponent("Imported.anglesite", isDirectory: true)

        await #expect(throws: Boom.self) {
            _ = try await SiteActions.importDirectory(
                source,
                toPackageAt: dest,
                displayName: "Imported",
                bootstrapGit: { _ in throw Boom() },
                register: { _ in
                    Issue.record("register must not run when bootstrap fails")
                    return SiteStore.Site(
                        id: "site-id",
                        name: "Imported",
                        packageURL: dest,
                        isValid: true,
                        missingSentinels: []
                    )
                }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
}
