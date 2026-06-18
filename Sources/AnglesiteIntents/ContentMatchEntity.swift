import AppIntents
import AnglesiteCore

/// The kind of content a search match refers to. An `AppEnum` so it appears as a typed
/// field in the auto-derived MCP/Shortcuts schema (not just a string).
public enum ContentMatchKind: String, AppEnum, Sendable {
    case page, post, image

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Content Kind" }
    public static var caseDisplayRepresentations: [ContentMatchKind: DisplayRepresentation] {
        [.page: "Page", .post: "Post", .image: "Image"]
    }
}

/// A uniform projection of a `PageEntity` / `PostEntity` / `ImageEntity` search hit.
/// `id` is the underlying entity's id ("{siteID}:{kind}:{path}"), so an agent can hand a
/// match straight to any intent that resolves the concrete type. `SearchContentIntent`
/// returns these so an agent can search-then-act across all three content kinds at once.
public struct ContentMatchEntity: AppEntity, Identifiable, Sendable {
    public let id: String
    @Property(title: "Kind") public var kind: ContentMatchKind
    @Property(title: "Title") public var title: String
    @Property(title: "Path") public var path: String   // route | slug | relativePath
    @Property(title: "Site") public var siteID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Content Match" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(kind.rawValue): \(path)")
    }

    public static let defaultQuery = ContentMatchEntityQuery()

    public init(id: String, kind: ContentMatchKind, title: String, path: String, siteID: String) {
        self.id = id; self.kind = kind; self.title = title; self.path = path; self.siteID = siteID
    }

    public init(_ p: PageEntity) {
        self.init(id: p.id, kind: .page, title: p.displayName, path: p.route, siteID: p.siteID)
    }
    public init(_ p: PostEntity) {
        self.init(id: p.id, kind: .post, title: p.displayName, path: p.slug, siteID: p.siteID)
    }
    public init(_ i: ImageEntity) {
        self.init(id: i.id, kind: .image, title: i.displayName, path: i.relativePath, siteID: i.siteID)
    }
}

/// Resolves `ContentMatchEntity` ids by routing each id to the concrete entity query based on
/// its ":page:" / ":post:" / ":image:" segment, then projecting. Input order is preserved.
public struct ContentMatchEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ContentMatchEntity] {
        let pages = try await PageEntityQuery()
            .entities(for: identifiers.filter { $0.contains(":page:") }).map(ContentMatchEntity.init)
        let posts = try await PostEntityQuery()
            .entities(for: identifiers.filter { $0.contains(":post:") }).map(ContentMatchEntity.init)
        let images = try await ImageEntityQuery()
            .entities(for: identifiers.filter { $0.contains(":image:") }).map(ContentMatchEntity.init)
        let byID = Dictionary(uniqueKeysWithValues: (pages + posts + images).map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0] }
    }

    public func suggestedEntities() async throws -> [ContentMatchEntity] { [] }
}
