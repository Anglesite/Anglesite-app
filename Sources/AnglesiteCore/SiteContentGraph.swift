import Foundation

/// In-memory projection of an Anglesite site's content (pages, posts, images), populated
/// by the MCP server's `list_content` response and kept in sync via file-watch events.
///
/// The filesystem is the source of truth — this is a read cache, not a database. The graph
/// holds no I/O surface, so it has no persistence: cold start is empty, and `LocalSiteRuntime`
/// (#142, A.8) repopulates per site open.
///
/// **Change handler.** Single-subscriber by design. Fires on real mutations only:
/// `upsert*` with an `Equatable`-equal existing entry does not emit. The signature passes the
/// siteID only — the subscriber (A.3 `ContentSpotlightIndexer`) reads pages/posts/images back
/// from the graph for diff computation. This keeps emit cheap and matches the existing
/// `SpotlightIndexer.reindex(_:)` "trust whatever the source publishes at moment of read"
/// pattern.
public actor SiteContentGraph {
    public struct Page: Sendable, Equatable, Identifiable {
        public let id: String          // "{siteID}:page:{route}"
        public let siteID: String
        public let route: String
        public let filePath: String
        public let title: String?
        public let lastModified: Date

        public init(
            id: String,
            siteID: String,
            route: String,
            filePath: String,
            title: String?,
            lastModified: Date
        ) {
            self.id = id
            self.siteID = siteID
            self.route = route
            self.filePath = filePath
            self.title = title
            self.lastModified = lastModified
        }
    }

    public struct Post: Sendable, Equatable, Identifiable {
        public let id: String          // "{siteID}:post:{slug}"
        public let siteID: String
        public let collection: String
        public let slug: String
        public let title: String
        public let draft: Bool
        public let publishDate: Date?
        public let tags: [String]
        public let filePath: String
        public let lastModified: Date

        public init(
            id: String,
            siteID: String,
            collection: String,
            slug: String,
            title: String,
            draft: Bool,
            publishDate: Date?,
            tags: [String],
            filePath: String,
            lastModified: Date
        ) {
            self.id = id
            self.siteID = siteID
            self.collection = collection
            self.slug = slug
            self.title = title
            self.draft = draft
            self.publishDate = publishDate
            self.tags = tags
            self.filePath = filePath
            self.lastModified = lastModified
        }
    }

    public struct Image: Sendable, Equatable, Identifiable {
        public let id: String          // "{siteID}:image:{relativePath}"
        public let siteID: String
        public let relativePath: String
        public let fileName: String
        public let byteSize: Int64?
        public let usedOnPages: [String]
        public let lastModified: Date

        public init(
            id: String,
            siteID: String,
            relativePath: String,
            fileName: String,
            byteSize: Int64?,
            usedOnPages: [String],
            lastModified: Date
        ) {
            self.id = id
            self.siteID = siteID
            self.relativePath = relativePath
            self.fileName = fileName
            self.byteSize = byteSize
            self.usedOnPages = usedOnPages
            self.lastModified = lastModified
        }
    }

    public typealias ChangeHandler = @Sendable (String) async -> Void

    private var pages: [String: Page] = [:]
    private var posts: [String: Post] = [:]
    private var images: [String: Image] = [:]
    private var changeHandler: ChangeHandler?

    public init() {}

    public func setChangeHandler(_ handler: ChangeHandler?) {
        changeHandler = handler
    }

    private func emitChange(_ siteID: String) async {
        guard let handler = changeHandler else { return }
        await handler(siteID)
    }
}
