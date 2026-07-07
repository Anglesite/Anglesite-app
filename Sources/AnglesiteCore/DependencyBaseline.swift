import Foundation

/// Reads/writes `Config/dependency-baseline.json` — a flat package-name ->
/// version-range snapshot of the template's `package.json` at the moment a site
/// was scaffolded (or, for a legacy site, at the moment its first dependency-sync
/// check ran). This is app-owned state, never committed to the site's git repo
/// (`Config/` is outside `Source/` — see the `.anglesite` package model).
public enum DependencyBaseline {
    public static let filename = "dependency-baseline.json"

    /// `nil` (not a throw) when the file is absent or unreadable — that's the
    /// normal "no baseline yet" case the 3-way diff's legacy fallback handles.
    public static func load(from configDirectory: URL) -> [String: String]? {
        let url = configDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    public static func save(_ packages: [String: String], to configDirectory: URL) throws {
        let url = configDirectory.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(packages)
        try data.write(to: url, options: .atomic)
    }
}
