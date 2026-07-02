import Foundation

/// App-facing content creation workflow.
///
/// Owns the full post-create lifecycle: delegate the write to the selected
/// `ContentOperationsService`, then rescan and publish the site's content graph after a successful
/// create. `SiteContentGraph.load` emits the graph change that drives the semantic indexer, so UI
/// and App Intent callers get the same refresh behavior.
public struct ContentCreationWorkflow: ContentOperationsService {
    public typealias SiteDirectoryResolver = @Sendable (_ siteID: String) async -> URL?
    public typealias PageTemplateCreator = @Sendable (
        _ siteID: String,
        _ title: String,
        _ route: String?,
        _ template: ContentScaffold.PageTemplate,
        _ onProgress: ProgressHandler?
    ) async -> ContentCreateResult
    public typealias TypedSlugCreator = @Sendable (
        _ siteID: String,
        _ typeID: String,
        _ title: String,
        _ slug: String?,
        _ onProgress: ProgressHandler?
    ) async -> ContentCreateResult

    private let operations: any ContentOperationsService
    private let contentGraph: SiteContentGraph?
    private let knowledgeIndex: SiteKnowledgeIndex?
    private let siteDirectory: SiteDirectoryResolver
    private let pageTemplateCreator: PageTemplateCreator?
    private let typedSlugCreator: TypedSlugCreator?

    public init(
        operations: any ContentOperationsService,
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex? = nil,
        siteDirectory: @escaping SiteDirectoryResolver,
        pageTemplateCreator: PageTemplateCreator? = nil,
        typedSlugCreator: TypedSlugCreator? = nil
    ) {
        self.operations = operations
        self.contentGraph = contentGraph
        self.knowledgeIndex = knowledgeIndex
        self.siteDirectory = siteDirectory
        self.pageTemplateCreator = pageTemplateCreator
        self.typedSlugCreator = typedSlugCreator
    }

    public static func native(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex? = nil,
        siteDirectory: @escaping SiteDirectoryResolver
    ) -> ContentCreationWorkflow {
        let copyGenerator = SettingsGatedPageCopyGenerator(
            isEnabled: { AppSettings.shared.autoGeneratePageCopy },
            base: PageCopyGeneratorFactory.makeDefault()
        )
        let native = NativeContentOperations(siteDirectory: siteDirectory, copyGenerator: copyGenerator)
        return ContentCreationWorkflow(
            operations: native,
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            siteDirectory: siteDirectory,
            pageTemplateCreator: { siteID, title, route, template, onProgress in
                await native.createPage(
                    siteID: siteID,
                    name: title,
                    route: route,
                    template: template,
                    onProgress: onProgress
                )
            },
            typedSlugCreator: { siteID, typeID, title, slug, onProgress in
                await native.createTyped(
                    siteID: siteID,
                    typeID: typeID,
                    title: title,
                    slug: slug,
                    onProgress: onProgress
                )
            }
        )
    }

    public func createPage(
        siteID: String,
        name: String,
        route: String?,
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        let result = await operations.createPage(
            siteID: siteID,
            name: name,
            route: route,
            onProgress: onProgress
        )
        await refreshContentGraphIfCreated(result, siteID: siteID)
        return result
    }

    public func createPage(
        siteID: String,
        title: String,
        route: String?,
        template: ContentScaffold.PageTemplate,
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        let result: ContentCreateResult
        if let pageTemplateCreator {
            result = await pageTemplateCreator(siteID, title, route, template, onProgress)
        } else {
            result = await operations.createPage(
                siteID: siteID,
                name: title,
                route: route,
                onProgress: onProgress
            )
        }
        await refreshContentGraphIfCreated(result, siteID: siteID)
        return result
    }

    public func createPost(
        siteID: String,
        title: String,
        collection: String?,
        slug: String?,
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        let result = await operations.createPost(
            siteID: siteID,
            title: title,
            collection: collection,
            slug: slug,
            onProgress: onProgress
        )
        await refreshContentGraphIfCreated(result, siteID: siteID)
        return result
    }

    public func createTyped(
        siteID: String,
        typeID: String,
        title: String,
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        let result = await operations.createTyped(
            siteID: siteID,
            typeID: typeID,
            title: title,
            onProgress: onProgress
        )
        await refreshContentGraphIfCreated(result, siteID: siteID)
        return result
    }

    public func createTyped(
        siteID: String,
        typeID: String,
        title: String,
        slug: String?,
        onProgress: ProgressHandler? = nil
    ) async -> ContentCreateResult {
        let result: ContentCreateResult
        if let typedSlugCreator {
            result = await typedSlugCreator(siteID, typeID, title, slug, onProgress)
        } else {
            result = await operations.createTyped(
                siteID: siteID,
                typeID: typeID,
                title: title,
                onProgress: onProgress
            )
        }
        await refreshContentGraphIfCreated(result, siteID: siteID)
        return result
    }

    private func refreshContentGraphIfCreated(_ result: ContentCreateResult, siteID: String) async {
        guard case let .created(filePath, _) = result, let root = await siteDirectory(siteID) else {
            return
        }
        if let contentGraph {
            let listing = await Task.detached(priority: .utility) {
                ContentScanner.scan(projectRoot: root, siteID: siteID)
            }.value
            await contentGraph.load(
                siteID: siteID,
                pages: listing.pages,
                posts: listing.posts,
                images: listing.images
            )
        }
        await knowledgeIndex?.upsertFile(siteID: siteID, projectRoot: root, relativePath: filePath)
    }
}
