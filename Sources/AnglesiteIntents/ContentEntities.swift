import AppIntents
import AnglesiteCore
import Foundation

// MARK: - PageEntity

/// An Anglesite page, addressable by Siri/Shortcuts. Backed live by `SiteContentGraph` —
/// no cache, so the entity never goes stale relative to the graph state.
public struct PageEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String            // "{siteID}:page:{route}" — same as SiteContentGraph.Page.id
    public let displayName: String   // title ?? route
    @Property(title: "Route") public var route: String
    @Property(title: "Site ID") public var siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Page" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(route)")
    }

    public static let defaultQuery = PageEntityQuery()

    public init(_ page: SiteContentGraph.Page) {
        self.id = page.id
        self.displayName = page.title ?? page.route
        self.route = page.route
        self.siteID = page.siteID
    }

    /// Direct field initializer — used to build a return value from data already in hand
    /// (e.g. a just-created page) without round-tripping through `SiteContentGraph`,
    /// which the file-watcher may not have indexed yet.
    public init(id: String, displayName: String, route: String, siteID: String) {
        self.id = id
        self.displayName = displayName
        self.route = route
        self.siteID = siteID
    }

    /// Build the entity an `AddPageIntent` returns. On success the route is the created
    /// identifier; on failure we return a best-effort entity from the requested input so the
    /// intent keeps a single `ReturnsValue<PageEntity>` type. The dialog — not this value — is
    /// the source of truth for whether creation actually succeeded.
    public static func make(
        siteID: String, name: String, requestedRoute: String?, result: ContentCreateResult
    ) -> PageEntity {
        let route: String
        switch result {
        case .created(_, let identifier): route = identifier
        case .siteNotFound, .failed:       route = requestedRoute ?? ""
        }
        return PageEntity(id: "\(siteID):page:\(route)", displayName: name, route: route, siteID: siteID)
    }
}

/// Resolves `PageEntity` references from `SiteContentGraph`. Used by Siri/Shortcuts for both
/// id round-trip (`entities(for:)`) and natural-language match (`entities(matching:)`).
public struct PageEntityQuery: EntityStringQuery {
    @Dependency private var graph: SiteContentGraph

    public init() {}

    private var resolved: SiteContentGraph {
        // Tests bind ContentGraphOverride.scoped; production goes through @Dependency.
        // The `??` short-circuits, so `graph` is only touched when no override is bound.
        ContentGraphOverride.scoped ?? graph
    }

    public func entities(for identifiers: [String]) async throws -> [PageEntity] {
        // Single actor hop for all ids (#170); the graph preserves input order and skips unknowns.
        await resolved.pages(ids: identifiers).map(PageEntity.init)
    }

    public func entities(matching string: String) async throws -> [PageEntity] {
        // Empty / whitespace-only query → []. The graph's searchPages returns everything on
        // empty input; surfacing that here would double up with suggestedEntities() during
        // AppIntents disambiguation prefetch. Keep the two surfaces distinct.
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let g = resolved
        var matches: [SiteContentGraph.Page] = []
        for siteID in await g.knownSiteIDs() {
            matches.append(contentsOf: await g.searchPages(siteID: siteID, matching: string))
        }
        return matches
            .sorted {
                $0.lastModified != $1.lastModified
                    ? $0.lastModified > $1.lastModified
                    : $0.id < $1.id
            }
            .map(PageEntity.init)
    }

    public func suggestedEntities() async throws -> [PageEntity] {
        let g = resolved
        var all: [SiteContentGraph.Page] = []
        for siteID in await g.knownSiteIDs() {
            all.append(contentsOf: await g.pages(for: siteID))
        }
        return all
            .sorted {
                $0.lastModified != $1.lastModified
                    ? $0.lastModified > $1.lastModified
                    : $0.id < $1.id
            }
            .map(PageEntity.init)
    }

    public func defaultResult() async -> PageEntity? { nil }
}

// MARK: - PostEntity

/// An Anglesite blog post / content-collection entry, addressable by Siri/Shortcuts.
public struct PostEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String            // "{siteID}:post:{slug}"
    public let displayName: String   // title
    @Property(title: "Slug") public var slug: String
    @Property(title: "Collection") public var collection: String
    @Property(title: "Site ID") public var siteID: String
    public let isDraft: Bool
    public let tags: [String]

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Post" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(collection)/\(slug)\(isDraft ? " (draft)" : "")"
        )
    }

    public static let defaultQuery = PostEntityQuery()

    public init(_ post: SiteContentGraph.Post) {
        self.id = post.id
        self.displayName = post.title
        self.isDraft = post.draft
        self.tags = post.tags
        self.slug = post.slug
        self.collection = post.collection
        self.siteID = post.siteID
    }

    public init(id: String, displayName: String, slug: String, collection: String,
                siteID: String, isDraft: Bool, tags: [String]) {
        self.id = id
        self.displayName = displayName
        self.isDraft = isDraft
        self.tags = tags
        self.slug = slug
        self.collection = collection
        self.siteID = siteID
    }

    /// `"src/content/{collection}/{slug}.md"` → `"{collection}"`. The collection is the path
    /// component immediately before the file. Returns nil when the path has no such parent.
    public static func collection(fromPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts[parts.count - 2]
    }

    /// Build the entity an `AddPostIntent` returns. Add Post scaffolds a *draft*, so `isDraft`
    /// is true and `tags` empty. The dialog is the source of truth for success vs. failure.
    public static func make(
        siteID: String, title: String, requestedCollection: String?, requestedSlug: String?,
        result: ContentCreateResult
    ) -> PostEntity {
        let slug: String
        let collection: String
        switch result {
        case .created(let filePath, let identifier):
            slug = identifier
            collection = Self.collection(fromPath: filePath) ?? requestedCollection ?? ""
        case .siteNotFound, .failed:
            slug = requestedSlug ?? ""
            collection = requestedCollection ?? ""
        }
        return PostEntity(id: "\(siteID):post:\(slug)", displayName: title, slug: slug,
                          collection: collection, siteID: siteID, isDraft: true, tags: [])
    }
}

/// Resolves `PostEntity` references from `SiteContentGraph`. Search covers title, slug, tags,
/// and collection name (delegated to `SiteContentGraph.searchPosts`).
public struct PostEntityQuery: EntityStringQuery {
    @Dependency private var graph: SiteContentGraph

    public init() {}

    private var resolved: SiteContentGraph {
        ContentGraphOverride.scoped ?? graph
    }

    public func entities(for identifiers: [String]) async throws -> [PostEntity] {
        // Single actor hop for all ids (#170); the graph preserves input order and skips unknowns.
        await resolved.posts(ids: identifiers).map(PostEntity.init)
    }

    public func entities(matching string: String) async throws -> [PostEntity] {
        // Empty / whitespace-only query → []. The graph's searchPosts returns everything on
        // empty input; surfacing that here would double up with suggestedEntities() during
        // AppIntents disambiguation prefetch. Keep the two surfaces distinct.
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let g = resolved
        var matches: [SiteContentGraph.Post] = []
        for siteID in await g.knownSiteIDs() {
            matches.append(contentsOf: await g.searchPosts(siteID: siteID, matching: string))
        }
        return matches
            .sorted {
                $0.lastModified != $1.lastModified
                    ? $0.lastModified > $1.lastModified
                    : $0.id < $1.id
            }
            .map(PostEntity.init)
    }

    public func suggestedEntities() async throws -> [PostEntity] {
        let g = resolved
        var all: [SiteContentGraph.Post] = []
        for siteID in await g.knownSiteIDs() {
            all.append(contentsOf: await g.posts(for: siteID))
        }
        return all
            .sorted {
                $0.lastModified != $1.lastModified
                    ? $0.lastModified > $1.lastModified
                    : $0.id < $1.id
            }
            .map(PostEntity.init)
    }

    public func defaultResult() async -> PostEntity? { nil }
}

// MARK: - ImageEntity

/// An image asset under `public/images/` (or anywhere referenced), addressable by Siri/Shortcuts.
public struct ImageEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String            // "{siteID}:image:{relativePath}"
    public let displayName: String   // fileName
    @Property(title: "Relative Path") public var relativePath: String
    @Property(title: "Site ID") public var siteID: String
    /// Page routes that reference this image. Carried in the struct (not surfaced in
    /// `displayRepresentation` today) so adding it later isn't a source-breaking AppEntity
    /// schema change for Shortcuts persistence / donated interactions.
    public let usedOnPages: [String]

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Image" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(relativePath)")
    }

    public static let defaultQuery = ImageEntityQuery()

    public init(_ image: SiteContentGraph.Image) {
        self.id = image.id
        self.displayName = image.fileName
        self.usedOnPages = image.usedOnPages
        self.relativePath = image.relativePath
        self.siteID = image.siteID
    }
}

/// Resolves `ImageEntity` references from `SiteContentGraph`. Search covers fileName and
/// relativePath (delegated to `SiteContentGraph.searchImages`).
public struct ImageEntityQuery: EntityStringQuery {
    @Dependency private var graph: SiteContentGraph

    public init() {}

    private var resolved: SiteContentGraph {
        ContentGraphOverride.scoped ?? graph
    }

    public func entities(for identifiers: [String]) async throws -> [ImageEntity] {
        // Single actor hop for all ids (#170); the graph preserves input order and skips unknowns.
        await resolved.images(ids: identifiers).map(ImageEntity.init)
    }

    public func entities(matching string: String) async throws -> [ImageEntity] {
        // Empty / whitespace-only query → []. The graph's searchImages returns everything on
        // empty input; surfacing that here would double up with suggestedEntities() during
        // AppIntents disambiguation prefetch. Keep the two surfaces distinct.
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let g = resolved
        var matches: [SiteContentGraph.Image] = []
        for siteID in await g.knownSiteIDs() {
            matches.append(contentsOf: await g.searchImages(siteID: siteID, matching: string))
        }
        return matches
            .sorted {
                $0.lastModified != $1.lastModified
                    ? $0.lastModified > $1.lastModified
                    : $0.id < $1.id
            }
            .map(ImageEntity.init)
    }

    public func suggestedEntities() async throws -> [ImageEntity] {
        let g = resolved
        var all: [SiteContentGraph.Image] = []
        for siteID in await g.knownSiteIDs() {
            all.append(contentsOf: await g.images(for: siteID))
        }
        return all
            .sorted {
                $0.lastModified != $1.lastModified
                    ? $0.lastModified > $1.lastModified
                    : $0.id < $1.id
            }
            .map(ImageEntity.init)
    }

    public func defaultResult() async -> ImageEntity? { nil }
}

// MARK: - ContentSearchResultEntity (F-2)

/// Discriminator for the flattened search result. `SearchContentIntent` spans three entity
/// types; `ReturnsValue<T>` needs one concrete type, so results carry their kind.
public enum ContentKind: String, AppEnum, Sendable {
    case page, post, image
    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Content Kind" }
    public static var caseDisplayRepresentations: [ContentKind: DisplayRepresentation] {
        [.page: "Page", .post: "Post", .image: "Image"]
    }
}

/// A single search hit, flattened across pages/posts/images. `id` is the *underlying* entity id
/// (e.g. "s1:page:/about"), so an agent can re-resolve the typed entity (PageEntity, …) to chain.
public struct ContentSearchResultEntity: AppEntity, Identifiable, Sendable {
    public let id: String
    @Property(title: "Kind")    public var kind: ContentKind
    @Property(title: "Title")   public var title: String
    @Property(title: "Locator") public var locator: String
    @Property(title: "Site ID") public var siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Search Result" }
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(locator)")
    }
    public static let defaultQuery = ContentSearchResultEntityQuery()

    public init(id: String, kind: ContentKind, title: String, locator: String, siteID: String) {
        self.id = id; self.kind = kind; self.title = title; self.locator = locator; self.siteID = siteID
    }
    public init(page e: PageEntity) {
        self.init(id: e.id, kind: .page, title: e.displayName, locator: e.route, siteID: e.siteID)
    }
    public init(post e: PostEntity) {
        self.init(id: e.id, kind: .post, title: e.displayName, locator: "\(e.collection)/\(e.slug)", siteID: e.siteID)
    }
    public init(image e: ImageEntity) {
        self.init(id: e.id, kind: .image, title: e.displayName, locator: e.relativePath, siteID: e.siteID)
    }
}

/// Re-resolves flattened results by parsing the kind token out of each id and delegating to the
/// graph's typed id lookups. Plain `EntityQuery` (not `EntityStringQuery`): string search lives on
/// the typed entity queries and on `SearchContentIntent` itself; this only needs id round-trip.
public struct ContentSearchResultEntityQuery: EntityQuery {
    @Dependency private var graph: SiteContentGraph
    public init() {}
    private var resolved: SiteContentGraph { ContentGraphOverride.scoped ?? graph }

    public func entities(for identifiers: [String]) async throws -> [ContentSearchResultEntity] {
        let g = resolved
        var pageIDs: [String] = [], postIDs: [String] = [], imageIDs: [String] = []
        for id in identifiers {
            // id == "{siteID}:{kind}:{rest}". The siteID is a filesystem path (no ":"), so splitting
            // on ":" with maxSplits 2 yields exactly [siteID, kind, rest]; parts[1] is the kind.
            let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            switch parts[1] {
            case "page": pageIDs.append(id)
            case "post": postIDs.append(id)
            case "image": imageIDs.append(id)
            default: continue
            }
        }
        async let pages = g.pages(ids: pageIDs)
        async let posts = g.posts(ids: postIDs)
        async let images = g.images(ids: imageIDs)
        let mapped = await (pages.map { ContentSearchResultEntity(page: PageEntity($0)) }
            + posts.map { ContentSearchResultEntity(post: PostEntity($0)) }
            + images.map { ContentSearchResultEntity(image: ImageEntity($0)) })
        // Preserve caller's id order.
        let order = Dictionary(uniqueKeysWithValues: identifiers.enumerated().map { ($1, $0) })
        return mapped.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }
}
