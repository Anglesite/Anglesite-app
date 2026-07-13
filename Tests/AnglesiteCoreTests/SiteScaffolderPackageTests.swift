import Testing
import Foundation
@testable import AnglesiteCore

struct SiteScaffolderPackageTests {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scaffold-pkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("scaffold creates a package and runs the template + git init + initial commit inside Source/")
    func scaffoldsIntoSource() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let template = root.appendingPathComponent("Template", isDirectory: true)
        try FileManager.default.createDirectory(at: template.appendingPathComponent("scripts"), withIntermediateDirectories: true)

        // Record the cwd each injected command was run in, which dir got `git init`, and which
        // dir got the initial commit.
        actor Spy { var cwds: [URL] = []; var gitInits: [URL] = []; var gitCommits: [URL] = []
            func cwd(_ u: URL?) { if let u { cwds.append(u) } }
            func git(_ u: URL) { gitInits.append(u) }
            func commit(_ u: URL) { gitCommits.append(u) }
        }
        let spy = Spy()

        let scaffolder = SiteScaffolder(
            sitesRoot: root,
            templateURL: template,
            catalog: ThemeCatalog(themes: []),
            run: { _, _, cwd in await spy.cwd(cwd); return .init(stdout: "", stderr: "", exitCode: 0) },
            gitInit: { src in await spy.git(src) },
            gitCommit: { src in await spy.commit(src) },
            register: { pkg in try SiteStore.Site.make(package: pkg) }
        )

        var doneID: String?
        for await step in scaffolder.scaffold(.init(siteType: .business, name: "Acme")) {
            if case .done(let id) = step { doneID = id }
            if case .failed(let s, let m) = step { Issue.record("scaffold failed at \(s): \(m)") }
        }

        let pkg = AnglesitePackage(url: root.appendingPathComponent("acme.anglesite", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: pkg.sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: pkg.infoPlistURL.path))
        #expect(doneID == (try pkg.readMarker().siteID.uuidString))
        // Template scaffold + npm install ran with cwd == Source/, and git init targeted Source/.
        #expect(await spy.cwds.allSatisfy { $0 == pkg.sourceURL })
        #expect(await spy.gitInits == [pkg.sourceURL])
        // The initial commit also targeted Source/, after git init.
        #expect(await spy.gitCommits == [pkg.sourceURL])
    }
}
