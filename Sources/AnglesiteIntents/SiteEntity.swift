import AppIntents
import AnglesiteCore
import Foundation

/// An Anglesite site, addressable by Siri/Shortcuts. Backed live by `SiteStore` — no
/// cache, so the entity never goes stale relative to the registry.
public struct SiteEntity: AppEntity, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let directory: URL

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Site" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(directory.path)")
    }

    public static let defaultQuery = SiteEntityQuery()

    public init(_ site: SiteStore.Site) {
        self.id = site.id
        self.displayName = site.name
        self.directory = site.path
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
