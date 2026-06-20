import Foundation

/// App-owned, per-site settings persisted inside the package's `Config/` directory (spec §4).
/// Deliberately minimal today — it exists so per-site state attaches to the package rather than
/// app-global `UserDefaults`. Add fields as features need them (YAGNI).
///
/// **Forward-compat rule:** every field MUST stay `Optional` (or carry a default-on-decode). The
/// plist on disk may have been written by an older build that lacked a field; a non-optional field
/// would make `PropertyListDecoder` throw on those files. Optional fields decode missing keys as
/// `nil`, so old and new configs both load. `SiteConfigStore.load()` also falls back to defaults
/// if a decode fails outright, but keeping fields optional is the primary guarantee.
public struct SiteSettings: Sendable, Codable, Equatable {
    /// Owner-facing display name override. `nil` falls back to the package marker's displayName.
    public var displayName: String?

    public init(displayName: String? = nil) {
        self.displayName = displayName
    }
}

/// Reads/writes `Config/settings.plist` for one package. Per-window; owned by the site window.
///
/// Forward infrastructure established by #242 P4 alongside the chat-history relocation into
/// `Config/`. Its first consumer — applying `SiteSettings.displayName` to the displayed site name —
/// is tracked in #266; until then `Config/` holds chat history and this settings file.
public actor SiteConfigStore {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(configDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = configDirectory.appendingPathComponent("settings.plist")
        self.fileManager = fileManager
    }

    /// Load settings, or a default (empty) `SiteSettings` when the file is absent or unreadable.
    ///
    /// A decode failure falls back to defaults rather than throwing: settings are non-critical
    /// (every field is optional with a sensible default), so a config written by a newer build, or
    /// a corrupt one, must never block opening a site — the next `save` rewrites it cleanly. I/O
    /// errors reading an existing file still throw.
    public func load() throws -> SiteSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else { return SiteSettings() }
        let data = try Data(contentsOf: fileURL)
        return (try? PropertyListDecoder().decode(SiteSettings.self, from: data)) ?? SiteSettings()
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
