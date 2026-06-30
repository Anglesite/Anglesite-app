import Foundation

/// App-facing content creation workflow.
///
/// Owns the full post-create lifecycle: delegate the write to the selected
/// `ContentOperationsService`, then rescan and publish the site's content graph after a successful
/// create. `SiteContentGraph.load` emits the graph change that drives the semantic indexer, so UI
/// and App Intent callers get the same refresh behavior.
public struct ContentCreationWorkflow: ContentOperationsService {
    public typealias SiteDirectoryResolver = @Sendable (_ siteID: String) async -> URL?

    private let operations: any ContentOperationsService
    private let contentGraph: SiteContentGraph?
    private let siteDirectory: SiteDirectoryResolver

    public init(
        operations: any ContentOperationsService,
        contentGraph: SiteContentGraph?,
        siteDirectory: @escaping SiteDirectoryResolver
    ) {
        self.operations = operations
        self.contentGraph = contentGraph
        self.siteDirectory = siteDirectory
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

    private func refreshContentGraphIfCreated(_ result: ContentCreateResult, siteID: String) async {
        guard case .created = result, let contentGraph, let root = await siteDirectory(siteID) else {
            return
        }
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
}
