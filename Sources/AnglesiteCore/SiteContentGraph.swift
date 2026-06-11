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

    // MARK: - Incremental remove

    /// Removes the page with the given id. Silently no-ops (no emit) if the id is unknown —
    /// reflects the file-watch reality where the plugin may report removals for files the
    /// graph never received via `upsert*` (out-of-order events on startup, etc).
    public func removePage(id: String) async {
        guard let removed = pages.removeValue(forKey: id) else { return }
        await emitChange(removed.siteID)
    }

    public func removePost(id: String) async {
        guard let removed = posts.removeValue(forKey: id) else { return }
        await emitChange(removed.siteID)
    }

    public func removeImage(id: String) async {
        guard let removed = images.removeValue(forKey: id) else { return }
        await emitChange(removed.siteID)
    }

    // MARK: - Teardown

    /// Drops all entries (pages, posts, images) for `siteID` and emits a change. Always
    /// emits — even if the site had no entries, subscribers may want the "site empty now"
    /// signal to prune internal tracking (e.g., A.3 Spotlight indexer's last-indexed set).
    public func unload(siteID: String) async {
        for id in pages.compactMap({ $0.value.siteID == siteID ? $0.key : nil }) {
            pages.removeValue(forKey: id)
        }
        for id in posts.compactMap({ $0.value.siteID == siteID ? $0.key : nil }) {
            posts.removeValue(forKey: id)
        }
        for id in images.compactMap({ $0.value.siteID == siteID ? $0.key : nil }) {
            images.removeValue(forKey: id)
        }
        await emitChange(siteID)
    }

    // MARK: - Queries (single)

    public func page(id: String) -> Page? { pages[id] }
    public func post(id: String) -> Post? { posts[id] }
    public func image(id: String) -> Image? { images[id] }

    // MARK: - Search

    /// Case-insensitive substring search on a page's `title` and `route`. Empty `query`
    /// returns all pages for the siteID (no filtering).
    public func searchPages(siteID: String, matching query: String) -> [Page] {
        let scoped = pages.values.filter { $0.siteID == siteID }
        guard !query.isEmpty else { return Array(scoped) }
        let needle = query.lowercased()
        return scoped.filter { page in
            if page.route.lowercased().contains(needle) { return true }
            if let title = page.title?.lowercased(), title.contains(needle) { return true }
            return false
        }
    }

    /// Case-insensitive substring search on a post's `title`, `slug`, `tags`, and
    /// `collection`. Empty `query` returns all posts for the siteID (no filtering).
    public func searchPosts(siteID: String, matching query: String) -> [Post] {
        let scoped = posts.values.filter { $0.siteID == siteID }
        guard !query.isEmpty else { return Array(scoped) }
        let needle = query.lowercased()
        return scoped.filter { post in
            if post.title.lowercased().contains(needle) { return true }
            if post.slug.lowercased().contains(needle) { return true }
            if post.collection.lowercased().contains(needle) { return true }
            if post.tags.contains(where: { $0.lowercased().contains(needle) }) { return true }
            return false
        }
    }
}
