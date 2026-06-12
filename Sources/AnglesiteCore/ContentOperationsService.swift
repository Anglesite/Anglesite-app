import Foundation

/// Side-effecting content operations an intent can drive (A.5, #139). Reads (search, status) go
/// straight to `SiteContentGraph`; this service covers the operations that spawn the plugin's MCP
/// server — `create_page` / `create_post` — so they're injectable behind a test seam the way
/// `SiteOperationsService` is for deploy/backup/audit.
public protocol ContentOperationsService: Sendable {
    func createPage(siteID: String, name: String, route: String?) async -> ContentCreateResult
    func createPost(siteID: String, title: String, collection: String?, slug: String?) async -> ContentCreateResult
}

/// Outcome of a `create_page` / `create_post` call.
public enum ContentCreateResult: Sendable, Equatable {
    /// `identifier` is the route (page) or slug (post). `filePath` is relative to the site root.
    case created(filePath: String, identifier: String)
    /// The site id didn't resolve to a known site directory.
    case siteNotFound
    /// The plugin reported an error, the MCP server couldn't start, or the reply was unparseable.
    case failed(reason: String)
}
