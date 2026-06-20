import Foundation

/// What selecting a navigator row does: navigate the preview to a route, or open a file in the editor.
public enum NavigatorTarget: Sendable, Equatable {
    case route(String)
    case file(FileRef)
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
    public let title: String
    public let items: [NavigatorItem]
    public init(id: FileGroup, title: String, items: [NavigatorItem]) {
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

/// Display titles for the five groups, in canonical sidebar order.
private let groupTitles: [(FileGroup, String)] = [
    (.pages, "Pages"), (.posts, "Posts"),
    (.components, "Components"), (.styles, "Styles"), (.metadata, "Metadata"),
]

/// Merges content-graph pages/posts with the filesystem scan into ordered, non-empty sections.
public func buildNavigatorTree(
    pages: [SiteContentGraph.Page],
    posts: [SiteContentGraph.Post],
    fileGroups: [FileGroup: [FileRef]]
) -> [NavigatorSection] {
    let pageItems = pages
        .sorted { $0.route < $1.route }
        .map { NavigatorItem(id: $0.id, title: $0.title ?? $0.route, target: .route($0.route)) }
    let postItems = posts
        .sorted { $0.title < $1.title }
        .map { NavigatorItem(id: $0.id, title: $0.title, target: .route(postRoute(for: $0))) }

    var sections: [NavigatorSection] = []
    for (group, title) in groupTitles {
        let items: [NavigatorItem]
        switch group {
        case .pages: items = pageItems
        case .posts: items = postItems
        default:
            items = (fileGroups[group] ?? []).map {
                NavigatorItem(id: $0.id, title: $0.name, target: .file($0))
            }
        }
        if !items.isEmpty { sections.append(NavigatorSection(id: group, title: title, items: items)) }
    }
    return sections
}
