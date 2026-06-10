import AppIntents
import AnglesiteCore
import Foundation

/// An Anglesite site, addressable by Siri/Shortcuts. Backed live by `SiteStore.shared` — no
/// cache, so the entity never goes stale relative to the registry.
struct SiteEntity: AppEntity, Identifiable {
    let id: String
    let displayName: String
    let directory: URL

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Site" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(directory.path)")
    }

    static var defaultQuery = SiteEntityQuery()

    init(_ site: SiteStore.Site) {
        self.id = site.id
        self.displayName = site.name
        self.directory = site.path
    }
}

/// Resolves sites by id (Shortcuts re-resolution) and by name (Siri "my portfolio site").
/// `load()` is called first so a cold background intent process sees the persisted registry.
struct SiteEntityQuery: EntityStringQuery {
    private func allSites() async -> [SiteStore.Site] {
        try? await SiteStore.shared.load()
        return await SiteStore.shared.sites
    }

    func entities(for identifiers: [String]) async throws -> [SiteEntity] {
        await allSites().filter { identifiers.contains($0.id) }.map(SiteEntity.init)
    }

    func entities(matching string: String) async throws -> [SiteEntity] {
        let needle = string.lowercased()
        return await allSites().filter { $0.name.lowercased().contains(needle) }.map(SiteEntity.init)
    }

    func suggestedEntities() async throws -> [SiteEntity] {
        await allSites().map(SiteEntity.init)
    }

    func defaultResult() async -> SiteEntity? {
        let sites = await allSites()
        return sites.count == 1 ? sites.first.map(SiteEntity.init) : nil
    }
}
