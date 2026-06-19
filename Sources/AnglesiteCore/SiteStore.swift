import Foundation

/// Recents registry for `.anglesite` packages opened in this app.
///
/// Each entry is keyed by the package's stable marker UUID (independent of filesystem path).
/// When a package is opened or created, the caller calls `record(_:)`, which reads the
/// `Info.plist` marker, upserts by UUID, and persists a most-recently-used–sorted list to
/// `recents.json`. `touch(id:)` bumps `lastSeen` without re-reading the marker (fast path
/// after a create/open that already called `record`).
///
/// The persisted list is the canonical source between launches: validity and last-seen
/// timestamps are cached so the UI renders immediately. `load()` restores the list on startup.
public actor SiteStore {
    /// Process-wide shared instance.
    public static let shared = SiteStore()

    public struct Site: Sendable, Codable, Equatable, Identifiable {
        /// The package's stable marker UUID (string). Path-independent — survives moves (#242).
        public let id: String
        /// Display name (from the package marker).
        public let name: String
        /// The `.anglesite` package directory.
        public let packageURL: URL
        public var isValid: Bool
        public var missingSentinels: [String]
        public var lastSeen: Date
        /// Security-scoped bookmark for `packageURL` (MAS). `nil` on DevID. One grant covers
        /// the whole package, so Source/ and Config/ are both reachable under it.
        public var bookmarkData: Data?

        /// The Astro project tree — every subprocess (scaffold, dev server, build, deploy,
        /// pre-deploy check) runs with this as its working directory.
        public var sourceDirectory: URL { AnglesitePackage(url: packageURL).sourceURL }
        /// App-owned per-site config dir (settings, chat history, cache).
        public var configDirectory: URL { AnglesitePackage(url: packageURL).configURL }

        public init(
            id: String,
            name: String,
            packageURL: URL,
            isValid: Bool,
            missingSentinels: [String],
            lastSeen: Date = Date(),
            bookmarkData: Data? = nil
        ) {
            self.id = id
            self.name = name
            self.packageURL = packageURL
            self.isValid = isValid
            self.missingSentinels = missingSentinels
            self.lastSeen = lastSeen
            self.bookmarkData = bookmarkData
        }

        /// Build a `Site` from a package on disk: id = marker UUID, name = marker displayName,
        /// validity = whether `Source/` passes the project sentinels.
        public static func make(package: AnglesitePackage, fileManager: FileManager = .default) throws -> Site {
            let marker = try package.readMarker(fileManager: fileManager)
            let validation = package.sourceValidation(fileManager: fileManager)
            return Site(
                id: marker.siteID.uuidString,
                name: marker.displayName,
                packageURL: canonicalizePackageURL(package.url),
                isValid: validation.isValid,
                missingSentinels: validation.missing
            )
        }
    }

    public enum StoreError: Error, Sendable {
        case notADirectory(URL)
        case invalidProject(URL, missing: [String])
    }

    /// Async callback invoked with the new site list after every mutation that changes the
    /// visible registry (load/record/remove/touch). Bookmark-only updates are not emitted —
    /// they don't affect what consumers like `SpotlightIndexer` care about. Single-subscriber
    /// by design; the indexer is the only known consumer today.
    public typealias ChangeHandler = @Sendable ([Site]) async -> Void

    private let fileManager: FileManager
    private let persistenceURL: URL
    private(set) public var sites: [Site] = []
    private var changeHandler: ChangeHandler?

    /// Continuations for the UI-observer broadcast, keyed by a per-subscription `UUID`.
    private var changeStreamContinuations: [UUID: AsyncStream<[Site]>.Continuation] = [:]

    /// - Parameters:
    ///   - persistenceURL: where to read/write `recents.json`. Defaults to
    ///     `~/Library/Application Support/Anglesite/recents.json`. Tests should pass a temp URL.
    ///   - fileManager: injection seam for tests.
    public init(
        persistenceURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
    }

    /// Install (or replace, or clear with `nil`) the post-mutation change handler.
    public func setChangeHandler(_ handler: ChangeHandler?) {
        changeHandler = handler
    }

    /// Loads the persisted site list from disk into memory. Safe to call before `record()`
    /// when the UI wants to render quickly. Skips the change emit on a fresh-install no-file
    /// path — there's nothing to propagate.
    public func load() async throws {
        guard fileManager.fileExists(atPath: persistenceURL.path) else {
            sites = []
            return
        }
        let data = try Data(contentsOf: persistenceURL)
        sites = try Self.decoder.decode([Site].self, from: data)
        await emitChange()
    }

    /// Add or update a recents entry for `package`. Reads its marker for identity + name and
    /// validates `Source/`. Upsert is by `id` (the marker UUID): re-opening a moved package
    /// updates its `packageURL` in place and carries any existing bookmark forward. Persists
    /// and emits a change.
    @discardableResult
    public func record(_ package: AnglesitePackage) async throws -> Site {
        var site = try Site.make(package: package, fileManager: fileManager)
        if let existing = sites.first(where: { $0.id == site.id }) {
            site.bookmarkData = existing.bookmarkData ?? site.bookmarkData
        }
        site.lastSeen = Date()
        sites.removeAll { $0.id == site.id }
        sites.append(site)
        sites.sort { $0.lastSeen > $1.lastSeen }
        try persist()
        await emitChange()
        return site
    }

    /// Bump `lastSeen` for the entry with `id` (most-recently-used ordering). No-op if unknown.
    public func touch(id: String) async throws {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[index].lastSeen = Date()
        sites.sort { $0.lastSeen > $1.lastSeen }
        try persist()
        await emitChange()
    }

    /// Removes a site from the list. Does not delete files on disk.
    public func remove(id: String) async throws {
        sites.removeAll { $0.id == id }
        try persist()
        await emitChange()
    }

    /// Look up a site by id.
    public func find(id: String) -> Site? {
        sites.first { $0.id == id }
    }

    /// The persisted security-scoped bookmark for a site, if any.
    public func bookmarkData(for id: String) -> Data? {
        sites.first { $0.id == id }?.bookmarkData
    }

    /// Stamp `bookmarkData` onto the site with the given id, then persist. No-op if unknown.
    public func setBookmark(_ data: Data, for id: String) throws {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[index].bookmarkData = data
        try persist()
    }

    // MARK: - Change notification

    public nonisolated func changeStream() -> AsyncStream<[Site]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.register(continuation, id: id) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func register(_ continuation: AsyncStream<[Site]>.Continuation, id: UUID) {
        changeStreamContinuations[id] = continuation
        continuation.yield(sites)
    }

    private func removeContinuation(_ id: UUID) {
        changeStreamContinuations[id] = nil
    }

    private func emitChange() async {
        if let handler = changeHandler {
            await handler(sites)
        }
        for continuation in changeStreamContinuations.values {
            continuation.yield(sites)
        }
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
            .appendingPathComponent("recents.json")
    }
}

/// Canonical (standardized, symlink-resolved) form of a package URL, so the same package
/// reached via a symlinked path collapses to one recents entry.
func canonicalizePackageURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}
