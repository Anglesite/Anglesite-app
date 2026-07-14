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

    /// Cloudflare account id owning this site's `INBOX_KV` namespace (#587). `nil` until a
    /// provisioning flow sets it — `InboxSubmissionSync` no-ops without both this and
    /// `inboxCaptureKVNamespaceID`.
    public var inboxCaptureAccountID: String?

    /// The provisioned `INBOX_KV` namespace id for this site (#587). See
    /// `inboxCaptureAccountID`.
    public var inboxCaptureKVNamespaceID: String?

    public init(displayName: String? = nil, inboxCaptureAccountID: String? = nil, inboxCaptureKVNamespaceID: String? = nil) {
        self.displayName = displayName
        self.inboxCaptureAccountID = inboxCaptureAccountID
        self.inboxCaptureKVNamespaceID = inboxCaptureKVNamespaceID
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
        try Self.read(from: fileURL.deletingLastPathComponent(), fileManager: fileManager)
    }

    /// Synchronous, actor-independent read of a package's `settings.plist`. Same contract as
    /// `load()` — absent or undecodable file → default `SiteSettings`; an I/O error reading an
    /// existing file throws. Exists so synchronous call sites (e.g. `SiteStore.Site.make`, which
    /// resolves the `displayName` override at construction, #266) can read settings without
    /// hopping onto the actor.
    ///
    /// - Important: Performs synchronous, blocking file I/O on the calling executor. Today's only
    ///   callers reach it via `Site.make` from `SiteStore` actor methods (off the main thread).
    ///   Do not call it — or `Site.make` — from a `@MainActor` context, or it will block the main
    ///   thread on disk.
    public nonisolated static func read(
        from configDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> SiteSettings {
        let fileURL = configDirectory.appendingPathComponent("settings.plist")
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
