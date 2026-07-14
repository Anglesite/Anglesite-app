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

/// Derived preview route for a post. See the plan's documented assumption.
public func postRoute(for post: SiteContentGraph.Post) -> String {
    // Percent-encode each component: a collection/slug with spaces, Unicode, or reserved chars
    // would otherwise produce an invalid URL path and 404 silently in the preview.
    let collection = post.collection.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? post.collection
    let slug = post.slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? post.slug
    return "/\(collection)/\(slug)/"
}
