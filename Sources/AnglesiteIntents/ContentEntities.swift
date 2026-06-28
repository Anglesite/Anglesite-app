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
    @Property(title: "Site") public var siteID: String

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

    public init(id: String, displayName: String, route: String, siteID: String) {
        self.id = id
        self.displayName = displayName
        self.route = route
        self.siteID = siteID
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
    @Property(title: "Type") public var contentType: String
    public let isDraft: Bool
    public let tags: [String]
    @Property(title: "Site") public var siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Post" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(collection)/\(slug)\(isDraft ? " (draft)" : "")"
        )
    }

    public static let defaultQuery = PostEntityQuery()

    /// Typed dimension (#351): map a post's collection back to its content type's display name via
    /// the registry; fall back to the raw collection for custom/unknown collections. Shared by both
    /// inits (and `AddPostIntent.createdPost`) so the derivation lives in exactly one place.
    public static func contentTypeName(forCollection collection: String) -> String {
        ContentTypeRegistry.default.descriptor(forCollection: collection)?.displayName ?? collection
    }

    public init(_ post: SiteContentGraph.Post) {
        self.id = post.id
        self.displayName = post.title
        self.isDraft = post.draft
        self.tags = post.tags
        self.slug = post.slug
        self.collection = post.collection
        self.siteID = post.siteID
        self.contentType = Self.contentTypeName(forCollection: post.collection)
    }

    public init(id: String, displayName: String, slug: String, collection: String,
                siteID: String, isDraft: Bool = true, tags: [String] = [],
                contentType: String = "") {
        self.id = id
        self.displayName = displayName
        self.isDraft = isDraft
        self.tags = tags
        self.slug = slug
        self.collection = collection
        self.siteID = siteID
        // A default-param can't reference `collection`, so derive when the caller omits it — this
        // keeps the Spotlight "Type" attribute from being indexed blank.
        self.contentType = contentType.isEmpty ? Self.contentTypeName(forCollection: collection) : contentType
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
    @Property(title: "Path") public var relativePath: String
    /// Page routes that reference this image. Carried in the struct (not surfaced in
    /// `displayRepresentation` today) so adding it later isn't a source-breaking AppEntity
    /// schema change for Shortcuts persistence / donated interactions.
    public let usedOnPages: [String]
    @Property(title: "Site") public var siteID: String

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
