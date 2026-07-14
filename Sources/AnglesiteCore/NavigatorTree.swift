import Foundation

/// What selecting a navigator row does: navigate the preview to a route, open a file in the
/// editor, open a directory's settings, or open the site-wide Website Settings (#714).
public enum NavigatorTarget: Sendable, Equatable {
    case route(String)
    case file(FileRef)
    case directory(collection: String?, route: String)
    case websiteSettings
}

public struct NavigatorItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let target: NavigatorTarget
    public init(id: String, title: String, target: NavigatorTarget) {
        self.id = id; self.title = title; self.target = target
    }
}

public struct NavigatorSection: Sendable, Equatable, Identifiable {
    public let id: FileGroup
    public let title: String?
    public let items: [NavigatorItem]
    public init(id: FileGroup, title: String?, items: [NavigatorItem]) {
        self.id = id; self.title = title; self.items = items
    }
}

/// Derived preview route for a post. See the plan's documented assumption.
public func postRoute(for post: SiteContentGraph.Post) -> String {
    // Percent-encode each component: a collection/slug with spaces, Unicode, or reserved chars
    // would otherwise produce an invalid URL path and 404 silently in the preview.
    let collection = post.collection.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? post.collection
    let slug = post.slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? post.slug
    return "/\(collection)/\(slug)/"
}

/// Display titles for the six groups, in canonical sidebar order.
private let groupTitles: [(FileGroup, String?)] = [
    (.metadata, nil), (.pages, "Pages"), (.posts, "Posts"), (.collections, "Collections"),
    (.components, "Components"), (.styles, "Styles"),
]

/// `SiteContentGraph.Post` covers every `src/content/<collection>/` entry, not just blog posts —
/// a "New Collection…" entry (e.g. a note or bookmark) is a `Post` too, just with a different
/// `collection`. This is the one collection name that's actually a blog post.
private let blogCollectionName = "posts"

/// Merges content-graph pages/posts with the filesystem scan into ordered, non-empty sections.
/// Splits `posts` by `collection`: blog posts (`collection == "posts"`) go to the Posts section;
/// everything else (notes, articles, bookmarks, …) goes to a separate Collections section so a
/// freshly-created collection entry doesn't read as "a post got created instead" (#586).
public func buildNavigatorTree(
    pages: [SiteContentGraph.Page],
    posts: [SiteContentGraph.Post],
    fileGroups: [FileGroup: [FileRef]],
    websiteTitle: String? = nil,
    contentTypes: ContentTypeRegistry = .default
) -> [NavigatorSection] {
    let pageItems = pages
        .sorted { $0.route < $1.route }
        .map { NavigatorItem(id: $0.id, title: $0.title ?? $0.route, target: .route($0.route)) }
    let postItems = posts
        .filter { $0.collection == blogCollectionName }
        .sorted { $0.title < $1.title }
        .map { NavigatorItem(id: $0.id, title: $0.title, target: .route(postRoute(for: $0))) }
    let collectionItems = posts
        .filter { $0.collection != blogCollectionName }
        .sorted { $0.collection == $1.collection ? $0.title < $1.title : $0.collection < $1.collection }
        .map { post in
            NavigatorItem(
                id: post.id,
                title: "\(collectionLabel(post.collection, contentTypes: contentTypes)): \(post.title)",
                target: .route(postRoute(for: post)))
        }

    var sections: [NavigatorSection] = []
    for (group, title) in groupTitles {
        let items: [NavigatorItem]
        switch group {
        case .pages: items = pageItems
        case .posts: items = postItems
        case .collections: items = collectionItems
        case .metadata:
            items = siteMetadataItems(from: fileGroups[group] ?? [], websiteTitle: websiteTitle)
        default:
            items = (fileGroups[group] ?? []).map {
                NavigatorItem(id: $0.id, title: $0.name, target: .file($0))
            }
        }
        if !items.isEmpty { sections.append(NavigatorSection(id: group, title: title, items: items)) }
    }
    return sections
}

/// A collection-entry's registered content type display name (e.g. `Note`), falling back to the
/// capitalized collection folder name for a collection with no matching descriptor.
private func collectionLabel(_ collection: String, contentTypes: ContentTypeRegistry) -> String {
    if let descriptor = contentTypes.descriptor(forCollection: collection) {
        return descriptor.displayName
    }
    guard let first = collection.first else { return collection }
    return first.uppercased() + collection.dropFirst()
}

private func siteMetadataItems(from refs: [FileRef], websiteTitle: String?) -> [NavigatorItem] {
    guard let infoPlist = refs.first(where: { $0.name == "Info.plist" }) else { return [] }
    let title = websiteTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    return [
        NavigatorItem(
            id: infoPlist.id,
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Website",
            target: .file(infoPlist)
        )
    ]
}
