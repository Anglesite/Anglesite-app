import Foundation

/// Side-effecting content operations an intent can drive (A.5, #139). Reads (search, status) go
/// straight to `SiteContentGraph`; this service covers the operations that spawn the plugin's MCP
/// server — `create_page` / `create_post` — so they're injectable behind a test seam the way
/// `SiteOperationsService` is for deploy/backup/audit.
public protocol ContentOperationsService: Sendable {
    func createPage(siteID: String, name: String, route: String?, onProgress: ProgressHandler?) async -> ContentCreateResult
    func createPost(siteID: String, title: String, collection: String?, slug: String?, onProgress: ProgressHandler?) async -> ContentCreateResult
    /// Scaffold a typed entry (V-1.2 personal/business content types) from the content-type registry.
    /// `typeID` is a registry id (`note`, `article`, …); `title` seeds the name/title field and the
    /// slug. Collection-stored types only — non-collection types (e.g. the `profile` identity singleton)
    /// report `.failed` — use `createTypedSingleton`.
    func createTyped(siteID: String, typeID: String, title: String, onProgress: ProgressHandler?) async -> ContentCreateResult
    // TODO: add `createTypedSingleton` here when remote runtimes land (#66/#69). It lives only on the
    // concrete `NativeContentOperations` today; protocol-typed call sites can't create singletons yet.
}

public extension ContentOperationsService {
    func createPage(siteID: String, name: String, route: String?) async -> ContentCreateResult {
        await createPage(siteID: siteID, name: name, route: route, onProgress: nil)
    }
    func createPost(siteID: String, title: String, collection: String?, slug: String?) async -> ContentCreateResult {
        await createPost(siteID: siteID, title: title, collection: collection, slug: slug, onProgress: nil)
    }
    func createTyped(siteID: String, typeID: String, title: String) async -> ContentCreateResult {
        await createTyped(siteID: siteID, typeID: typeID, title: title, onProgress: nil)
    }
}

/// Outcome of a `create_page` / `create_post` / `create_content` call.
public enum ContentCreateResult: Sendable, Equatable {
    /// `identifier` is the route (page) or slug (post / typed entry). `filePath` is relative to the site root.
    case created(filePath: String, identifier: String)
    /// The site id didn't resolve to a known site directory.
    case siteNotFound
    /// The plugin reported an error, the MCP server couldn't start, or the reply was unparseable.
    case failed(reason: String)
}

/// Outcome of a `delete_content` call.
public enum ContentDeleteResult: Sendable, Equatable {
    case deleted(filePath: String)
    /// The site id didn't resolve to a known site directory.
    case siteNotFound
    /// The file didn't exist, or the git delete+commit failed (dirty tree, no HEAD copy,
    /// rejecting hook, git missing).
    case failed(reason: String)
}
