// Sources/AnglesiteCore/ProjectConventionsEngine.swift
import Foundation

/// Shared, app-lifetime, in-memory index of each open site's `ProjectConventions` — mirrors
/// `SiteKnowledgeIndex`'s shape and lifecycle exactly (same `rebuild`/`upsertFile`/`removeFile`
/// triggers, driven by the same `SiteFileWatcher`, see Task 6).
///
/// Deliberately in-memory only, like `SiteKnowledgeIndex`'s embedding cache today: per-site
/// `Config/` persistence is owned by `ProjectConventionsStore` (Task 6) and driven by the
/// UI-facing `ProjectConventionsModel` (Task 9), not by this actor. `seed(siteID:with:)` lets a
/// caller preload a persisted value (so overrides survive an app restart) before the first
/// `rebuild` runs its merge.
public actor ProjectConventionsEngine {
    private var conventionsBySite: [String: ProjectConventions] = [:]
    private var filesBySite: [String: [String: String]] = [:]

    public init() {}

    public func rebuild(siteID: String, projectRoot: URL) async {
        let files = await Task.detached(priority: .utility) {
            Self.scan(projectRoot: projectRoot)
        }.value
        filesBySite[siteID] = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.contents) })
        await recompute(siteID: siteID, projectRoot: projectRoot)
    }

    public func upsertFile(siteID: String, projectRoot: URL, relativePath: String) async {
        guard shouldScan(relativePath) else { return }
        let url = projectRoot.appendingPathComponent(relativePath)
        let contents = await Task.detached(priority: .utility) {
            try? String(contentsOf: url, encoding: .utf8)
        }.value
        guard let contents else {
            await removeFile(siteID: siteID, relativePath: relativePath)
            return
        }
        filesBySite[siteID, default: [:]][relativePath] = contents
        await recompute(siteID: siteID, projectRoot: projectRoot)
    }

    public func removeFile(siteID: String, relativePath: String) async {
        guard filesBySite[siteID]?.removeValue(forKey: relativePath) != nil else { return }
        // No projectRoot available here (mirrors SiteKnowledgeIndex.removeFile) — frontmatter
        // collections are re-read from disk on the next full `rebuild`, not on every removal.
        await recompute(siteID: siteID, projectRoot: nil)
    }

    public func unload(siteID: String) {
        conventionsBySite.removeValue(forKey: siteID)
        filesBySite.removeValue(forKey: siteID)
    }

    public func conventions(siteID: String) -> ProjectConventions? {
        conventionsBySite[siteID]
    }

    /// Preloads a value (typically read from `Config/conventions.json` by the caller) before the
    /// first `rebuild` for this site, so a subsequent `rebuild`'s merge preserves its overrides.
    /// No-op if a value is already present (a real `rebuild` has already run this session).
    public func seed(siteID: String, with conventions: ProjectConventions) {
        guard conventionsBySite[siteID] == nil else { return }
        conventionsBySite[siteID] = conventions
    }

    public func applyOverride(siteID: String, value: OverrideValue) {
        var conventions = conventionsBySite[siteID] ?? .empty
        conventions.apply(value)
        conventionsBySite[siteID] = conventions
    }

    public func clearOverride(siteID: String, field: OverridableField) {
        guard var conventions = conventionsBySite[siteID] else { return }
        conventions.clearOverride(field)
        conventionsBySite[siteID] = conventions
    }

    // MARK: - Recompute

    private func recompute(siteID: String, projectRoot: URL?) async {
        let files = (filesBySite[siteID] ?? [:]).map {
            ProjectConventionsExtractor.ScannedFile(path: $0.key, contents: $0.value)
        }
        var fresh = ProjectConventionsExtractor.extract(files: files)
        if let projectRoot {
            let collections = await Task.detached(priority: .utility) {
                FrontmatterSchemaReader.read(siteDirectory: projectRoot)
            }.value
            fresh.frontmatter = FrontmatterConventions(collections: collections)
        } else if let previous = conventionsBySite[siteID] {
            // No projectRoot on this call (a `removeFile` with no disk access) — keep the
            // last-known frontmatter reading rather than blanking it out.
            fresh.frontmatter = previous.frontmatter
        }
        if let previous = conventionsBySite[siteID] {
            fresh = fresh.merging(overriddenFrom: previous)
        }
        conventionsBySite[siteID] = fresh
    }

    // MARK: - Scanning

    private func shouldScan(_ relativePath: String) -> Bool {
        guard !SiteIndexPaths.isSkipped(relativePath: relativePath) else { return false }
        return Self.scannedExtensions.contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased())
    }

    private static let scannedExtensions: Set<String> = ["astro", "md", "mdx", "html"]

    private static func scan(projectRoot: URL) -> [ProjectConventionsExtractor.ScannedFile] {
        walk(projectRoot).compactMap { url -> ProjectConventionsExtractor.ScannedFile? in
            guard let relativePath = SiteIndexPaths.relativePOSIXPath(of: url, under: projectRoot),
                  scannedExtensions.contains(url.pathExtension.lowercased()),
                  let contents = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            return ProjectConventionsExtractor.ScannedFile(path: relativePath, contents: contents)
        }
    }

    private static func walk(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if SiteIndexPaths.skippedDirectoryNames.contains(entry.lastPathComponent) { continue }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                files.append(contentsOf: walk(entry))
            } else {
                files.append(entry)
            }
        }
        return files
    }
}
