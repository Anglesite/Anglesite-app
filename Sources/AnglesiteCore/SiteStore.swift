import Foundation

/// Manages the list of Anglesite sites known to the app.
///
/// Sites live in `~/Sites/<name>/` (or wherever `AppSettings.sitesRoot` points). The store
/// discovers them by scanning that root for directories that pass `ProjectValidator`, then
/// persists the resulting list as JSON in `~/Library/Application Support/Anglesite/sites.json`.
///
/// The persisted list is the canonical source between launches: we cache validity and last-seen
/// timestamps so the UI can render immediately without re-scanning the filesystem. `refresh()`
/// reconciles the cache with what's actually on disk.
public actor SiteStore {
    /// Process-wide shared instance. Multi-window code reads/writes through this so the
    /// in-memory list and on-disk sites.json stay coherent across windows.
    public static let shared = SiteStore()

    public struct Site: Sendable, Codable, Equatable, Identifiable {
        public let id: String          // path-derived, stable across launches
        public let name: String        // last path component
        public let path: URL
        public var isValid: Bool
        public var missingSentinels: [String]
        public var lastSeen: Date
        /// Security-scoped bookmark for `path`. Populated via the MAS "Open Folder…" flow
        /// (NSOpenPanel grants access; we stamp a bookmark so the grant survives relaunch).
        /// `nil` for the DevID build (no sandbox) and for sites found by directory scan, which
        /// can't mint a bookmark without an explicit user grant. Optional so existing
        /// sites.json files decode unchanged.
        public var bookmarkData: Data?

        public init(
            id: String,
            name: String,
            path: URL,
            isValid: Bool,
            missingSentinels: [String],
            lastSeen: Date = Date(),
            bookmarkData: Data? = nil
        ) {
            self.id = id
            self.name = name
            self.path = path
            self.isValid = isValid
            self.missingSentinels = missingSentinels
            self.lastSeen = lastSeen
            self.bookmarkData = bookmarkData
        }
    }

    public enum StoreError: Error, Sendable {
        case notADirectory(URL)
        case invalidProject(URL, missing: [String])
    }

    private let fileManager: FileManager
    private let settings: AppSettings
    private let persistenceURL: URL
    private(set) public var sites: [Site] = []

    /// - Parameters:
    ///   - settings: settings store consulted for `sitesRoot`.
    ///   - persistenceURL: where to read/write `sites.json`. Defaults to
    ///     `~/Library/Application Support/Anglesite/sites.json`. Tests should pass a temp URL.
    ///   - fileManager: injection seam for tests.
    public init(
        settings: AppSettings = .shared,
        persistenceURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.settings = settings
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
    }

    /// Loads the persisted site list from disk into memory. Safe to call before `refresh()`
    /// when the UI wants to render quickly without waiting for filesystem validation.
    public func load() throws {
        guard fileManager.fileExists(atPath: persistenceURL.path) else {
            sites = []
            return
        }
        let data = try Data(contentsOf: persistenceURL)
        sites = try Self.decoder.decode([Site].self, from: data)
    }

    /// Scans `settings.sitesRoot` for project directories, validates each, merges with the
    /// existing in-memory list, and persists. Returns the new list.
    @discardableResult
    public func refresh() throws -> [Site] {
        let root = settings.sitesRoot
        let discovered: [Site]
        if fileManager.fileExists(atPath: root.path) {
            let entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            discovered = entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .map { url in
                    let result = ProjectValidator.validate(url, fileManager: fileManager)
                    let canonical = Self.canonicalize(url)
                    return Site(
                        id: Self.identifier(for: canonical),
                        name: canonical.lastPathComponent,
                        path: canonical,
                        isValid: result.isValid,
                        missingSentinels: result.missing,
                        lastSeen: Date()
                    )
                }
                .filter { $0.isValid || !$0.missingSentinels.elementsEqual(ProjectValidator.sentinels) }
                // Drop dirs with zero sentinels — they're not Anglesite sites at all.
        } else {
            discovered = []
        }

        // Merge: keep manually-added sites that aren't under `root` (and are still valid),
        // refresh anything we just rediscovered, drop stale entries that no longer exist.
        var byID: [String: Site] = [:]
        for site in sites where fileManager.fileExists(atPath: site.path.path) {
            byID[site.id] = site
        }
        for var site in discovered {
            // Re-discovery rebuilds a Site from the filesystem with no bookmark; carry forward
            // any persisted security-scoped bookmark so a refresh doesn't strip the grant.
            site.bookmarkData = byID[site.id]?.bookmarkData ?? site.bookmarkData
            byID[site.id] = site
        }
        sites = byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try persist()
        return sites
    }

    /// Adds a site by absolute path. Validates first; throws if the directory isn't an Anglesite project.
    @discardableResult
    public func add(_ url: URL) throws -> Site {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw StoreError.notADirectory(url)
        }
        let result = ProjectValidator.validate(url, fileManager: fileManager)
        guard result.isValid else {
            throw StoreError.invalidProject(url, missing: result.missing)
        }
        // Canonicalize once so id, path, and name all derive from the same
        // symlink-resolved form — NSOpenPanel hands us paths that may differ
        // from the resolved form by a /private prefix or a symlinked root (#56).
        let canonical = Self.canonicalize(url)
        let site = Site(
            id: Self.identifier(for: canonical),
            name: canonical.lastPathComponent,
            path: canonical,
            isValid: true,
            missingSentinels: [],
            lastSeen: Date()
        )
        sites.removeAll { $0.id == site.id }
        sites.append(site)
        sites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try persist()
        return site
    }

    /// Removes a site from the list. Does not delete files on disk.
    public func remove(id: String) throws {
        sites.removeAll { $0.id == id }
        try persist()
    }

    /// Look up a site by id. Convenience used by window scenes that receive the id as a
    /// `WindowGroup(for:)` value and need to resolve it to a path/name.
    public func find(id: String) -> Site? {
        sites.first { $0.id == id }
    }

    /// The persisted security-scoped bookmark for a site, if any. `nil` in DevID and for
    /// scan-discovered sites that were never granted via NSOpenPanel.
    public func bookmarkData(for id: String) -> Data? {
        sites.first { $0.id == id }?.bookmarkData
    }

    /// Stamp `bookmarkData` onto the site with the given id, then persist. No-op if unknown.
    public func setBookmark(_ data: Data, for id: String) throws {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[index].bookmarkData = data
        try persist()
    }

    // MARK: - Persistence

    private func persist() throws {
        let dir = persistenceURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(sites)
        try data.write(to: persistenceURL, options: [.atomic])
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// The canonical file URL for `url`: standardized and symlink-resolved. The single
    /// resolved form that `id`, `path`, and `name` are all derived from, so a site reached
    /// via a symlinked root (e.g. `/tmp` → `/private/tmp`) collapses to one stable entry (#56).
    static func canonicalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func identifier(for url: URL) -> String {
        // Standardize so "/Users/x/Sites/foo" and "/Users/x/Sites/foo/" resolve to the same id.
        canonicalize(url).path
    }

    private static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Anglesite", isDirectory: true)
            .appendingPathComponent("sites.json")
    }
}
