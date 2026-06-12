import AppIntents
import AnglesiteCore
import Foundation

// MARK: - PageEntity

/// An Anglesite page, addressable by Siri/Shortcuts. Backed live by `SiteContentGraph` —
/// no cache, so the entity never goes stale relative to the graph state.
public struct PageEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    public let id: String            // "{siteID}:page:{route}" — same as SiteContentGraph.Page.id
    public let displayName: String   // title ?? route
    public let route: String
    public let siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Page" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(route)")
    }

    public static var defaultQuery = PageEntityQuery()

    public init(_ page: SiteContentGraph.Page) {
        self.id = page.id
        self.displayName = page.title ?? page.route
        self.route = page.route
        self.siteID = page.siteID
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
        let g = resolved
        var found: [PageEntity] = []
        for id in identifiers {
            if let page = await g.page(id: id) {
                found.append(PageEntity(page))
            }
        }
        return found
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
    public let slug: String
    public let collection: String
    public let siteID: String
    public let isDraft: Bool
    public let tags: [String]

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Post" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(collection)/\(slug)\(isDraft ? " (draft)" : "")"
        )
    }

    public static var defaultQuery = PostEntityQuery()

    public init(_ post: SiteContentGraph.Post) {
        self.id = post.id
        self.displayName = post.title
        self.slug = post.slug
        self.collection = post.collection
        self.siteID = post.siteID
        self.isDraft = post.draft
        self.tags = post.tags
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
        let g = resolved
        var found: [PostEntity] = []
        for id in identifiers {
            if let post = await g.post(id: id) {
                found.append(PostEntity(post))
            }
        }
        return found
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
    public let relativePath: String
    public let siteID: String
    /// Page routes that reference this image. Carried in the struct (not surfaced in
    /// `displayRepresentation` today) so adding it later isn't a source-breaking AppEntity
    /// schema change for Shortcuts persistence / donated interactions.
    public let usedOnPages: [String]

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Image" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(relativePath)")
    }

    public static var defaultQuery = ImageEntityQuery()

    public init(_ image: SiteContentGraph.Image) {
        self.id = image.id
        self.displayName = image.fileName
        self.relativePath = image.relativePath
        self.siteID = image.siteID
        self.usedOnPages = image.usedOnPages
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
        let g = resolved
        var found: [ImageEntity] = []
        for id in identifiers {
            if let image = await g.image(id: id) {
                found.append(ImageEntity(image))
            }
        }
        return found
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
