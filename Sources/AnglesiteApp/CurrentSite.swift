import Foundation
import AnglesiteCore

/// The identity and on-disk paths for a site window's currently open site (#822).
///
/// Before this type existed, `SiteWindowModel.loadAndStart` re-derived `id`/`sourceDirectory`/
/// `packageURL`/`configDirectory` from `SiteStore.Site` separately at each of six child models'
/// own call sites (`PreviewModel.open`, `SiteNavigatorModel.start`, `ProjectCleanupModel.configure`,
/// `SiteGraphExplorerModel.start`, and — via `ComponentEditorContext` — `ComponentEditorModel`),
/// each reading a different subset of the same three-ish fields off the same `SiteStore.Site`
/// value. That's harmless as long as every call site reads the same local, but it's a stale-state
/// bug waiting to happen the moment one of those calls moves to a different lifecycle point than
/// the others (e.g. a future replay path that resolves the site twice). Threading one
/// `CurrentSite`, constructed once per site open/replay, closes that off: every child model
/// downstream of `loadAndStart` sees the exact same values.
///
/// Deliberately narrower than `SiteStore.Site` — this carries only what a child model needs to
/// operate on a site's *files*, not the mutable registry bookkeeping (`isValid`,
/// `missingSentinels`, `lastSeen`, `bookmarkData`, `needsReauthorization`) that only
/// `SiteWindowModel` itself and the launcher care about.
///
/// Not threaded into `ChatModel`/`SiteAssistantSessionFactory`: that factory's `makeSession`
/// intentionally takes `siteID`/`sourceDirectory`/`configDirectory`/an *optional* `packageURL`
/// as disaggregated parameters — `packageURL` is optional on purpose (see
/// `SiteAssistantSessionFactoryTests.missingPackageURLMeansNoFactory`, which exercises the
/// no-design-interview-factory branch), and `CurrentSite.packageURL` is never optional for a
/// real open site. Forcing `CurrentSite` through that boundary would either fight the factory's
/// existing optionality contract or require a second, parallel "maybe a site" type — not worth
/// it for a factory `SiteWindowModel` already calls through `AssistantSessionAssembler`.
struct CurrentSite: Equatable, Sendable {
    let id: String
    let name: String
    let packageURL: URL
    let sourceDirectory: URL
    let configDirectory: URL

    init(_ site: SiteStore.Site) {
        self.id = site.id
        self.name = site.name
        self.packageURL = site.packageURL
        self.sourceDirectory = site.sourceDirectory
        self.configDirectory = site.configDirectory
    }

    /// Fixture initializer: builds a `CurrentSite` directly from its component values, without
    /// going through a `SiteStore.Site` (which needs a real, on-disk `.anglesite` package layout
    /// to compute `sourceDirectory`/`configDirectory` from). For tests that construct child
    /// models directly against a plain temp directory rather than a full package fixture.
    /// `name`/`configDirectory` default for call sites that don't exercise them.
    init(id: String, name: String = "", packageURL: URL, sourceDirectory: URL, configDirectory: URL? = nil) {
        self.id = id
        self.name = name
        self.packageURL = packageURL
        self.sourceDirectory = sourceDirectory
        self.configDirectory = configDirectory ?? sourceDirectory
    }
}
