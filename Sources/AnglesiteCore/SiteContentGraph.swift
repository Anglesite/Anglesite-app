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

    // MARK: - Bulk load

    /// Replaces all entries for `siteID` with the supplied payload. Existing entries for
    /// other siteIDs are untouched. Always emits a change for `siteID`.
    public func load(
        siteID: String,
        pages: [Page],
        posts: [Post],
        images: [Image]
    ) async {
        for key in self.pages.compactMap({ $0.value.siteID == siteID ? $0.key : nil }) {
            self.pages.removeValue(forKey: key)
        }
        for key in self.posts.compactMap({ $0.value.siteID == siteID ? $0.key : nil }) {
            self.posts.removeValue(forKey: key)
        }
        for key in self.images.compactMap({ $0.value.siteID == siteID ? $0.key : nil }) {
            self.images.removeValue(forKey: key)
        }
        for page in pages { self.pages[page.id] = page }
        for post in posts { self.posts[post.id] = post }
        for image in images { self.images[image.id] = image }
        await emitChange(siteID)
    }

    // MARK: - Queries (per-site)

    public func pages(for siteID: String) -> [Page] {
        pages.values.filter { $0.siteID == siteID }
    }

    public func posts(for siteID: String) -> [Post] {
        posts.values.filter { $0.siteID == siteID }
    }

    public func images(for siteID: String) -> [Image] {
        images.values.filter { $0.siteID == siteID }
    }

    // MARK: - Incremental upsert

    public func upsertPage(_ page: Page) async {
        if pages[page.id] == page { return }
        pages[page.id] = page
        await emitChange(page.siteID)
    }

    public func upsertPost(_ post: Post) async {
        if posts[post.id] == post { return }
        posts[post.id] = post
        await emitChange(post.siteID)
    }

    public func upsertImage(_ image: Image) async {
        if images[image.id] == image { return }
        images[image.id] = image
        await emitChange(image.siteID)
    }

    // MARK: - Queries (single)

    public func page(id: String) -> Page? { pages[id] }
    public func post(id: String) -> Post? { posts[id] }
    public func image(id: String) -> Image? { images[id] }
}
