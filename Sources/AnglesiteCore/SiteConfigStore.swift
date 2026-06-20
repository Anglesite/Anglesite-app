import Foundation

/// App-owned, per-site settings persisted inside the package's `Config/` directory (spec §4).
/// Deliberately minimal today — it exists so per-site state attaches to the package rather than
/// app-global `UserDefaults`. Add fields as features need them (YAGNI).
public struct SiteSettings: Sendable, Codable, Equatable {
    /// Owner-facing display name override. `nil` falls back to the package marker's displayName.
    public var displayName: String?

    public init(displayName: String? = nil) {
        self.displayName = displayName
    }
}

/// Reads/writes `Config/settings.plist` for one package. Per-window; owned by the site window.
public actor SiteConfigStore {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(configDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = configDirectory.appendingPathComponent("settings.plist")
        self.fileManager = fileManager
    }

    /// Load settings, or a default (empty) `SiteSettings` when the file doesn't exist yet.
    public func load() throws -> SiteSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else { return SiteSettings() }
        let data = try Data(contentsOf: fileURL)
        return try PropertyListDecoder().decode(SiteSettings.self, from: data)
    }

    /// Persist settings to `settings.plist` (XML plist, atomic), creating `Config/` if needed.
    public func save(_ settings: SiteSettings) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }
}
