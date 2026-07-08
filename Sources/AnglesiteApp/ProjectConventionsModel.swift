// Sources/AnglesiteApp/ProjectConventionsModel.swift
import Foundation
import AnglesiteCore

/// Per-site, UI-facing wrapper around the shared `ProjectConventionsEngine`. Owns the
/// `Config/conventions.json` round trip (via `ProjectConventionsStore`) so persistence only
/// happens on explicit user-driven actions (rescan, override, clear-override) — background
/// re-learns triggered by the file watcher update the in-memory engine value (which
/// `AltTextGenerator` reads immediately) but are not separately persisted to disk until the next
/// explicit action here.
@MainActor
@Observable
final class ProjectConventionsModel {
    private let engine: ProjectConventionsEngine
    private let store: ProjectConventionsStore
    private let siteID: String
    private let siteDirectory: URL

    private(set) var conventions: ProjectConventions?
    private(set) var isLearning = false
    var sheetPresented = false

    init(engine: ProjectConventionsEngine, siteID: String, siteDirectory: URL, configDirectory: URL) {
        self.engine = engine
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.store = ProjectConventionsStore(configDirectory: configDirectory)
    }

    /// Seeds the shared engine from any persisted override in `Config/conventions.json`.
    /// Must run before the site runtime's first `rebuild` for this site — `engine.seed(...)` is
    /// a no-op once any value is already present, so if the runtime's boot-time rebuild runs
    /// first, a persisted override is silently discarded. Safe to call more than once.
    func seedFromDisk() async {
        if let persisted = await store.load() {
            await engine.seed(siteID: siteID, with: persisted)
        }
    }

    /// Opens the sheet. `seedFromDisk()` should already have run before the site's runtime
    /// booted (see `SiteWindowModel.loadAndStart`); this call is a safety net in case a caller
    /// opens the sheet through some other path that skipped it.
    func presentSheet() async {
        await seedFromDisk()
        conventions = await engine.conventions(siteID: siteID)
        sheetPresented = true
    }

    func rescan() async {
        isLearning = true
        await engine.rebuild(siteID: siteID, projectRoot: siteDirectory, forceEnrichment: true)
        conventions = await engine.conventions(siteID: siteID)
        if let conventions {
            await store.save(conventions)
        }
        isLearning = false
    }

    func setOverride(_ value: OverrideValue) async {
        await engine.applyOverride(siteID: siteID, value: value)
        conventions = await engine.conventions(siteID: siteID)
        if let conventions {
            await store.save(conventions)
        }
    }

    func clearOverride(_ field: OverridableField) async {
        await engine.clearOverride(siteID: siteID, field: field)
        conventions = await engine.conventions(siteID: siteID)
        if let conventions {
            await store.save(conventions)
        }
    }
}
