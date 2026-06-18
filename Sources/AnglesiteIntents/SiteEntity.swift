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
    public var id: String
    @Property(title: "Name")
    public var name: String
    @Property(title: "Creation Date")
    public var creationDate: Date?
    @Property(title: "Modification Date")
    public var modificationDate: Date?

    /// The original display name used by `displayRepresentation` and `SiteEntityQuery`.
    public var displayName: String { name }
    /// The directory on disk backing this site. Not exposed as a schema property —
    /// it is app-internal state used by `displayRepresentation`.
    public var directory: URL = URL(fileURLWithPath: "/")

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(directory.path)")
    }

    public static let defaultQuery = SiteEntityQuery()

    public init(_ site: SiteStore.Site) {
        self.id = site.id
        self.name = site.name
        self.directory = site.path

        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let values = try? site.path.resourceValues(forKeys: keys)
        self.creationDate = values?.creationDate
        self.modificationDate = values?.contentModificationDate
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
