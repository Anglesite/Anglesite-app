import Foundation

/// Testable command kernel for the app target's Cocoa Scripting adapters.
///
/// AppleScript commands are synchronous Objective-C entry points, but the work they trigger is
/// already async Swift. Keep policy, site resolution, and result formatting here so the app target
/// can stay a small Apple Event adapter instead of growing another operation stack.
public struct AppleScriptCommandService: Sendable {
    public enum CommandError: LocalizedError, Equatable {
        case emptySiteSpecifier
        case siteNotFound(String)
        case ambiguousSite(String, matches: [String])
        case deployRequiresUnattendedOptIn(String)

        public var errorDescription: String? {
            switch self {
            case .emptySiteSpecifier:
                return "Specify a site by UUID, exact name, or registered package path."
            case .siteNotFound(let specifier):
                return "Could not find a registered Anglesite site matching \(specifier)."
            case .ambiguousSite(let specifier, let matches):
                return "More than one site matches \(specifier): \(matches.joined(separator: ", "))."
            case .deployRequiresUnattendedOptIn(let name):
                return "Deploying \(name) from AppleScript requires `with allowing unattended`."
            }
        }
    }

    private let store: SiteStore
    private let operations: any SiteOperationsService
    private let content: any ContentOperationsService
    private let graph: SiteContentGraph
    private let loadSites: @Sendable () async throws -> Void

    public init(
        store: SiteStore = .shared,
        operations: (any SiteOperationsService)? = nil,
        content: (any ContentOperationsService)? = nil,
        graph: SiteContentGraph = SiteContentGraph(),
        loadSites: (@Sendable () async throws -> Void)? = nil
    ) {
        self.store = store
        self.operations = operations ?? SiteOperations(store: store)
        self.graph = graph
        self.loadSites = loadSites ?? { try await store.load() }
        self.content = content ?? ContentCreationWorkflow.native(
            contentGraph: graph,
            siteDirectory: { id in await store.find(id: id)?.sourceDirectory }
        )
    }

    public func resolveSite(_ specifier: String) async throws -> SiteStore.Site {
        let needle = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { throw CommandError.emptySiteSpecifier }

        try await loadSites()
        let sites = await store.sites

        if let site = sites.first(where: { $0.id.caseInsensitiveCompare(needle) == .orderedSame }) {
            return site
        }

        let pathMatches = sites.filter { site in
            let canonicalNeedle = Self.canonicalPath(needle)
            guard !canonicalNeedle.isEmpty else { return false }
            return canonicalNeedle == Self.canonicalPath(site.packageURL.path)
                || canonicalNeedle == Self.canonicalPath(site.sourceDirectory.path)
        }
        if let resolved = try singleMatch(pathMatches, specifier: needle) {
            return resolved
        }

        let nameMatches = sites.filter { $0.name.caseInsensitiveCompare(needle) == .orderedSame }
        if let resolved = try singleMatch(nameMatches, specifier: needle) {
            return resolved
        }

        throw CommandError.siteNotFound(needle)
    }

    public func openSite(_ specifier: String) async throws -> SiteStore.Site {
        let site = try await resolveSite(specifier)
        try? await store.touch(id: site.id)
        return site
    }

    public func deploySite(_ specifier: String, allowingUnattended: Bool) async throws -> String {
        let site = try await resolveSite(specifier)
        guard allowingUnattended else {
            throw CommandError.deployRequiresUnattendedOptIn(site.name)
        }
        return SiteOperations.dialog(forDeploy: await operations.deploy(site: site))
    }

    public func backupSite(_ specifier: String) async throws -> String {
        let site = try await resolveSite(specifier)
        return SiteOperations.dialog(forBackup: await operations.backup(site: site))
    }

    public func auditSite(_ specifier: String) async throws -> String {
        let site = try await resolveSite(specifier)
        return SiteOperations.dialog(forAudit: await operations.audit(site: site))
    }

    public func siteStatus(_ specifier: String) async throws -> String {
        let site = try await resolveSite(specifier)
        let posts = await graph.posts(for: site.id)
        let pages = await graph.pages(for: site.id).count
        let images = await graph.images(for: site.id).count
        let drafts = posts.filter(\.draft).count
        return "\(site.name) has \(Self.count(pages, "page")), \(Self.count(posts.count, "post")) (\(Self.count(drafts, "draft"))), and \(Self.count(images, "image"))."
    }

    public func addPage(_ specifier: String, name: String, route: String?) async throws -> String {
        let site = try await resolveSite(specifier)
        let cleanRoute = Self.nilIfBlank(route)
        let result = await content.createPage(siteID: site.id, name: name, route: cleanRoute)
        return Self.createdDialog(result, kind: "page", siteName: site.name)
    }

    public func addPost(_ specifier: String, title: String, collection: String?, slug: String?) async throws -> String {
        let site = try await resolveSite(specifier)
        let result = await content.createPost(
            siteID: site.id,
            title: title,
            collection: Self.nilIfBlank(collection),
            slug: Self.nilIfBlank(slug)
        )
        return Self.createdDialog(result, kind: "post", siteName: site.name)
    }

    private func singleMatch(_ matches: [SiteStore.Site], specifier: String) throws -> SiteStore.Site? {
        switch matches.count {
        case 0:
            return nil
        case 1:
            return matches[0]
        default:
            throw CommandError.ambiguousSite(specifier, matches: matches.map(\.name).sorted())
        }
    }

    private static func createdDialog(_ result: ContentCreateResult, kind: String, siteName: String) -> String {
        switch result {
        case .created(_, let identifier):
            return "Added a \(kind) at \(identifier) on \(siteName)."
        case .siteNotFound:
            return "Could not find \(siteName)."
        case .failed(let reason):
            return "Could not add the \(kind): \(reason)"
        }
    }

    private static func count(_ value: Int, _ singular: String) -> String {
        value == 1 ? "1 \(singular)" : "\(value) \(singular)s"
    }

    private static func nilIfBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func canonicalPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return "" }
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
