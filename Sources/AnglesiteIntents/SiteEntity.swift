import AppIntents
import AnglesiteCore
import Foundation

/// An Anglesite site, addressable by Siri/Shortcuts. Backed live by `SiteStore` — no
/// cache, so the entity never goes stale relative to the registry.
///
/// Conforms to the `.wordProcessor.document` AppSchema so Siri/Spotlight treat each site
/// as a document container. The schema macro synthesises `typeDisplayRepresentation`, so
/// the explicit override is omitted here (the metadata processor requires its removal).
@AppEntity(schema: .wordProcessor.document)
public struct SiteEntity: Sendable {
    public let id: String
    @Property(title: "Name")
    public var name: String
    @Property(title: "Creation Date")
    public var creationDate: Date?
    @Property(title: "Modification Date")
    public var modificationDate: Date?

    /// The original display name used by `displayRepresentation` and `SiteEntityQuery`.
    public var displayName: String { name }
    /// The `.anglesite` **package root** (`SiteStore.Site.packageURL`) — NOT the `Source/` git
    /// repo, so scaffolding, file scans, and git ops must not use this URL directly: derive
    /// `AnglesitePackage(url:).sourceURL` from it (see `ApplyThemeIntent`), or resolve the site
    /// by `id` via `SiteStore`/`SiteAccess.withScopedAccess`, which hands back `sourceDirectory`.
    /// App-internal rather than a schema `@Property`; nil only if AppIntents ever builds the
    /// entity via the macro init.
    public var directory: URL?

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(directory?.path(percentEncoded: false) ?? "")")
    }

    public static let defaultQuery = SiteEntityQuery()

    public init(id: String, name: String, creationDate: Date?, modificationDate: Date?, directory: URL? = nil) {
        self.id = id
        self.name = name
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.directory = directory
    }

    public init(_ site: SiteStore.Site) {
        // Directory mtime misses in-file edits; revisit with git timestamps after #68.
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let values = try? site.sourceDirectory.resourceValues(forKeys: keys)
        self.init(
            id: site.id,
            name: site.name,
            creationDate: values?.creationDate,
            modificationDate: values?.contentModificationDate,
            directory: site.packageURL
        )
    }
}

/// Resolves sites by id (Shortcuts re-resolution) and by name (Siri "my portfolio site").
/// `load()` is called first so a cold background intent process sees the persisted registry.
public struct SiteEntityQuery: EntityStringQuery {
    private let store: SiteStore

    public init() {
        self.store = .shared
    }

    public init(store: SiteStore) {
        self.store = store
    }

    private func allSites() async -> [SiteStore.Site] {
        try? await store.load()
        return await store.sites
    }

    public func entities(for identifiers: [String]) async throws -> [SiteEntity] {
        await allSites().filter { identifiers.contains($0.id) }.map(SiteEntity.init)
    }

    public func entities(matching string: String) async throws -> [SiteEntity] {
        let needle = string.lowercased()
        return await allSites().filter { $0.name.lowercased().contains(needle) }.map(SiteEntity.init)
    }

    public func suggestedEntities() async throws -> [SiteEntity] {
        await allSites().map(SiteEntity.init)
    }

    public func defaultResult() async -> SiteEntity? {
        let sites = await allSites()
        return sites.count == 1 ? sites.first.map(SiteEntity.init) : nil
    }
}
