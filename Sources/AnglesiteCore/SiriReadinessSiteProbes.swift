import Foundation

/// Reports whether a site's content is loaded into the in-memory graph (the data Siri's
/// search/status intents read). Empty is a warning, not a failure — the user just needs to
/// open the site.
public struct ContentGraphProbe: ReadinessProbe {
    public let id = "site.graph"
    public let title = "Site content index"
    private let siteID: String
    private let graph: SiteContentGraph

    public init(siteID: String, graph: SiteContentGraph) {
        self.siteID = siteID
        self.graph = graph
    }

    public func check() async -> ReadinessFinding {
        let pages = await graph.pages(for: siteID).count
        let posts = await graph.posts(for: siteID).count
        let images = await graph.images(for: siteID).count
        if pages + posts + images > 0 {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "\(pages) pages, \(posts) posts, \(images) images are loaded for Siri to search.")
        }
        return ReadinessFinding(id: id, title: title, level: .warning,
            detail: "No content is loaded for this site yet.",
            remediation: "Open this site's window so Anglesite can index its content.")
    }
}
