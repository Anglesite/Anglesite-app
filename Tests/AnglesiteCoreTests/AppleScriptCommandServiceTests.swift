import Foundation
import Testing
@testable import AnglesiteCore

@Suite("AppleScriptCommandService")
struct AppleScriptCommandServiceTests {
    @Test("resolves by UUID, exact name, package path, and source path")
    func resolvesExactIdentifiers() async throws {
        let fixture = try await Fixture()
        let service = fixture.service()

        #expect(try await service.resolveSite(fixture.alpha.id).id == fixture.alpha.id)
        #expect(try await service.resolveSite("Alpha").id == fixture.alpha.id)
        #expect(try await service.resolveSite(fixture.alpha.packageURL.path).id == fixture.alpha.id)
        #expect(try await service.resolveSite(fixture.alpha.sourceDirectory.path).id == fixture.alpha.id)
    }

    @Test("does not resolve name substrings")
    func rejectsSubstringResolution() async throws {
        let fixture = try await Fixture()
        let service = fixture.service()

        await #expect(throws: AppleScriptCommandService.CommandError.siteNotFound("Alp")) {
            _ = try await service.resolveSite("Alp")
        }
    }

    @Test("duplicate exact names are reported as ambiguous")
    func reportsAmbiguousExactNames() async throws {
        let fixture = try await Fixture()
        _ = try await fixture.recordPackage(directoryName: "Alpha Copy", displayName: "Alpha")
        let service = fixture.service()

        await #expect(throws: AppleScriptCommandService.CommandError.ambiguousSite("Alpha", matches: ["Alpha", "Alpha"])) {
            _ = try await service.resolveSite("Alpha")
        }
    }

    @Test("deploy requires explicit unattended opt-in")
    func deployRequiresOptIn() async throws {
        let fixture = try await Fixture()
        let service = fixture.service(
            operations: FakeSiteOperations(deployResult: .succeeded(url: URL(string: "https://example.com")!, duration: 1))
        )

        await #expect(throws: AppleScriptCommandService.CommandError.deployRequiresUnattendedOptIn("Alpha")) {
            _ = try await service.deploySite("Alpha", allowingUnattended: false)
        }

        let dialog = try await service.deploySite("Alpha", allowingUnattended: true)
        #expect(dialog == "Deployed to https://example.com.")
    }

    @Test("site status reports graph counts")
    func statusUsesContentGraph() async throws {
        let fixture = try await Fixture()
        let graph = SiteContentGraph()
        await graph.load(
            siteID: fixture.alpha.id,
            pages: [
                .init(
                    id: "\(fixture.alpha.id):page:/about",
                    siteID: fixture.alpha.id,
                    route: "/about",
                    filePath: "src/pages/about.md",
                    title: "About",
                    lastModified: Date()
                )
            ],
            posts: [
                .init(
                    id: "\(fixture.alpha.id):post:hello",
                    siteID: fixture.alpha.id,
                    collection: "blog",
                    slug: "hello",
                    title: "Hello",
                    draft: true,
                    publishDate: nil,
                    tags: [],
                    filePath: "src/content/blog/hello.md",
                    lastModified: Date()
                )
            ],
            images: [
                .init(
                    id: "\(fixture.alpha.id):image:/hero.png",
                    siteID: fixture.alpha.id,
                    relativePath: "public/hero.png",
                    fileName: "hero.png",
                    byteSize: 10,
                    usedOnPages: [],
                    lastModified: Date()
                )
            ]
        )

        let status = try await fixture.service(graph: graph).siteStatus("Alpha")
        #expect(status == "Alpha has 1 page, 1 post (1 draft), and 1 image.")
    }

    @Test("add page and add post format content operation results")
    func contentCreationDialogs() async throws {
        let fixture = try await Fixture()
        let content = FakeContentOperations(
            pageResult: .created(filePath: "src/pages/about.md", identifier: "/about"),
            postResult: .failed(reason: "slug already exists")
        )
        let service = fixture.service(content: content)

        #expect(try await service.addPage("Alpha", name: "About", route: " /about ") == "Added a page at /about on Alpha.")
        #expect(
            try await service.addPost("Alpha", title: "Hello", collection: nil, slug: nil)
                == "Could not add the post: slug already exists"
        )
    }

    private final class Fixture {
        let tempDir: URL
        let store: SiteStore
        let alpha: SiteStore.Site

        init() async throws {
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("applescript-service-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            store = SiteStore(persistenceURL: tempDir.appendingPathComponent("recents.json"))
            alpha = try await Self.recordPackage(
                in: tempDir,
                store: store,
                directoryName: "Alpha",
                displayName: "Alpha"
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: tempDir)
        }

        func recordPackage(directoryName: String, displayName: String) async throws -> SiteStore.Site {
            try await Self.recordPackage(
                in: tempDir,
                store: store,
                directoryName: directoryName,
                displayName: displayName
            )
        }

        func service(
            operations: (any SiteOperationsService)? = nil,
            content: (any ContentOperationsService)? = nil,
            graph: SiteContentGraph = SiteContentGraph()
        ) -> AppleScriptCommandService {
            AppleScriptCommandService(
                store: store,
                operations: operations,
                content: content,
                graph: graph,
                loadSites: {}
            )
        }

        private static func recordPackage(
            in tempDir: URL,
            store: SiteStore,
            directoryName: String,
            displayName: String
        ) async throws -> SiteStore.Site {
            let packageURL = tempDir.appendingPathComponent("\(directoryName).anglesite", isDirectory: true)
            let (package, _) = try AnglesitePackage.createSkeleton(at: packageURL, displayName: displayName)
            for sentinel in ProjectValidator.requiredSentinels {
                let url = package.sourceURL.appendingPathComponent(sentinel)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url)
            }
            return try await store.record(package)
        }
    }
}

private struct FakeSiteOperations: SiteOperationsService {
    var deployResult: DeployCommand.Result = .failed(reason: "unstubbed deploy", exitCode: nil)
    var backupResult: BackupCommand.Result = .failed(reason: "unstubbed backup", exitCode: nil)
    var auditResult: AuditCommand.Result = .failed(reason: "unstubbed audit", exitCode: nil, logTail: [])

    func site(id: String) async -> SiteStore.Site? { nil }
    func deploy(site: SiteStore.Site, onProgress: ProgressHandler?) async -> DeployCommand.Result { deployResult }
    func backup(site: SiteStore.Site, onProgress: ProgressHandler?) async -> BackupCommand.Result { backupResult }
    func audit(site: SiteStore.Site, onProgress: ProgressHandler?) async -> AuditCommand.Result { auditResult }
    func provisionSocialWorker(site: SiteStore.Site) async -> SocialWorkerProvisionCommand.Result {
        .failed(reason: "unstubbed social worker provisioning", exitCode: nil, resources: .init())
    }
}

private struct FakeContentOperations: ContentOperationsService {
    var pageResult: ContentCreateResult = .failed(reason: "unstubbed page")
    var postResult: ContentCreateResult = .failed(reason: "unstubbed post")

    func createPage(siteID: String, name: String, route: String?, onProgress: ProgressHandler?) async -> ContentCreateResult {
        pageResult
    }

    func createPost(siteID: String, title: String, collection: String?, slug: String?, onProgress: ProgressHandler?) async -> ContentCreateResult {
        postResult
    }

    func createTyped(siteID: String, typeID: String, title: String, onProgress: ProgressHandler?) async -> ContentCreateResult {
        .failed(reason: "unstubbed typed content")
    }
}
