import Foundation
import Observation
import AnglesiteCore

@MainActor
@Observable
final class PlistEditorModel {
    let file: FileRef
    let sourceDirectory: URL
    private let initialWebsiteTitle: String
    private let analyticsProvider: any CloudflareWebAnalyticsProviding
    private let customAnalyticsValidator: any CustomAnalyticsHTMLValidating
    private let keychain: KeychainStore
    var entries: [PlistDocumentIO.PlistEntry] = []
    private(set) var savedEntries: [PlistDocumentIO.PlistEntry] = []
    private var allEntries: [PlistDocumentIO.PlistEntry] = []
    private(set) var lastModified: Date?
    private(set) var loadError: String?
    private(set) var iconError: String?
    private(set) var analyticsError: String?
    private(set) var isLoading = false
    private(set) var isInstallingIcons = false
    private(set) var isSavingAnalytics = false
    private(set) var isConfiguringCloudflareAnalytics = false
    private(set) var hasWebsiteIcons = false
    var analyticsSettings = WebsiteAnalyticsAsset.Settings() {
        didSet {
            if oldValue.customHeadTag != analyticsSettings.customHeadTag {
                analyticsError = nil
            }
        }
    }
    private(set) var savedAnalyticsSettings = WebsiteAnalyticsAsset.Settings()
    var redirectEntries: [RedirectsStore.RedirectEntry] = []
    private(set) var savedRedirectEntries: [RedirectsStore.RedirectEntry] = []
    private(set) var redirectsError: String?
    private(set) var isSavingRedirects = false
    var conflictDiskContents: String?

    var isDirty: Bool { entries != savedEntries && loadError == nil && !isLoading }
    var isAnalyticsDirty: Bool { analyticsSettings != savedAnalyticsSettings && loadError == nil && !isLoading }
    var isRedirectsDirty: Bool { redirectEntries != savedRedirectEntries && loadError == nil && !isLoading }
    var cloudflareAnalyticsEnabled: Bool { !analyticsSettings.cloudflareToken.isEmpty }
    var customAnalyticsValidationMessage: String? {
        WebsiteAnalyticsAsset.customHeadTagValidationMessage(analyticsSettings.customHeadTag)
    }

    var validationMessage: String? {
        for entry in entries {
            if case .unsupported(let description) = entry.value {
                return "\(entry.key) is a \(description.lowercased()) value, which this editor can't save yet."
            }
        }
        return nil
    }

    var websiteTitle: String {
        get {
            guard let entry = entries.first, case .string(let title) = entry.value else { return "" }
            return title
        }
        set {
            guard let index = entries.firstIndex(where: Self.isWebsiteTitleEntry) else { return }
            entries[index].value = .string(newValue)
        }
    }

    init(file: FileRef, websiteTitle: String, sourceDirectory: URL,
         analyticsProvider: any CloudflareWebAnalyticsProviding = CloudflareWebAnalyticsClient(),
         customAnalyticsValidator: any CustomAnalyticsHTMLValidating = AstroHTMLValidator(),
         keychain: KeychainStore = KeychainStore()) {
        self.file = file
        self.initialWebsiteTitle = websiteTitle
        self.sourceDirectory = sourceDirectory
        self.analyticsProvider = analyticsProvider
        self.customAnalyticsValidator = customAnalyticsValidator
        self.keychain = keychain
        self.hasWebsiteIcons = WebsiteIconInstaller.hasInstalledIcons(in: sourceDirectory)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let url = file.url
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try PlistDocumentIO.load(url)
            }.value
            var visibleEntries = loaded.entries.filter(Self.isWebsiteTitleEntry)
            if let index = visibleEntries.firstIndex(where: Self.isWebsiteTitleEntry) {
                visibleEntries[index].value = .string(initialWebsiteTitle)
            }
            allEntries = loaded.entries
            entries = visibleEntries
            savedEntries = visibleEntries
            lastModified = loaded.modificationDate
            loadError = nil
            hasWebsiteIcons = WebsiteIconInstaller.hasInstalledIcons(in: sourceDirectory)
            let analytics = try Self.loadAnalyticsSettings(sourceDirectory: sourceDirectory)
            analyticsSettings = analytics
            savedAnalyticsSettings = analytics
            analyticsError = nil
            let redirects = (try? RedirectsStore(sourceDirectory: sourceDirectory).load()) ?? []
            redirectEntries = redirects
            savedRedirectEntries = redirects
            redirectsError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// True while `save()`'s off-main write is in flight — same contract as
    /// `FileEditorModel.isSaving` (analytics writes have their own `isSavingAnalytics`).
    private(set) var isSaving = false

    @discardableResult
    func save() async -> Bool {
        guard isDirty, !isSaving else { return true }
        guard validationMessage == nil else { return false }
        isSaving = true
        defer { isSaving = false }
        let url = file.url
        let entries = entriesForSaving()
        do {
            let mtime = try await Task.detached(priority: .userInitiated) {
                try PlistDocumentIO.save(entries, to: url)
            }.value
            lastModified = mtime
            allEntries = entries
            savedEntries = self.entries
            return true
        } catch {
            loadError = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func flushBeforeLeaving() async -> Bool {
        if isDirty {
            let url = file.url
            let known = lastModified
            let change = try? await Task.detached(priority: .userInitiated) {
                try PlistDocumentIO.externalChange(at: url, lastKnownModificationDate: known, bufferIsDirty: true)
            }.value
            if case .conflict(let disk)? = change {
                conflictDiskContents = disk
                return false
            }
            guard await save() else { return false }
        }
        if isAnalyticsDirty {
            guard await saveAnalytics() else { return false }
        }
        if isRedirectsDirty {
            return await saveRedirects()
        }
        return true
    }

    func checkExternalChange() async {
        guard loadError == nil else { return }
        let url = file.url
        let known = lastModified
        let dirty = isDirty
        let change = try? await Task.detached(priority: .userInitiated) {
            try PlistDocumentIO.externalChange(at: url, lastKnownModificationDate: known, bufferIsDirty: dirty)
        }.value
        guard let change else { return }
        switch change {
        case .none:
            break
        case .reloadable:
            await load()
        case .conflict(let disk):
            conflictDiskContents = disk
        }
    }

    func keepMyChanges() { conflictDiskContents = nil }

    func reloadFromDisk() async {
        conflictDiskContents = nil
        await load()
    }

    func installWebsiteIcons(from imageURL: URL) async {
        guard !isInstallingIcons else { return }
        isInstallingIcons = true
        iconError = nil
        defer { isInstallingIcons = false }

        let siteName = websiteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? initialWebsiteTitle
            : websiteTitle
        let sourceDirectory = sourceDirectory
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try WebsiteIconInstaller.install(from: imageURL, siteName: siteName, siteDirectory: sourceDirectory)
            }.value
            hasWebsiteIcons = true
        } catch {
            iconError = error.localizedDescription
        }
    }

    @discardableResult
    func saveAnalytics() async -> Bool {
        guard isAnalyticsDirty else { return true }
        guard !isSavingAnalytics else { return false }
        let sourceDirectory = sourceDirectory
        let settings = analyticsSettings
        if let validationMessage = await customAnalyticsValidator.validationMessage(
            for: settings.customHeadTag,
            siteDirectory: sourceDirectory
        ) ?? customAnalyticsValidationMessage {
            analyticsError = validationMessage
            return false
        }
        isSavingAnalytics = true
        analyticsError = nil
        defer { isSavingAnalytics = false }

        do {
            try await Task.detached(priority: .userInitiated) {
                try WebsiteAnalyticsAsset.install(settings, siteDirectory: sourceDirectory)
            }.value
            savedAnalyticsSettings = settings
            return true
        } catch {
            analyticsError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveRedirects() async -> Bool {
        guard isRedirectsDirty else { return true }
        guard !isSavingRedirects else { return false }
        isSavingRedirects = true
        redirectsError = nil
        defer { isSavingRedirects = false }
        let sourceDirectory = sourceDirectory
        let entries = redirectEntries
        do {
            try await Task.detached(priority: .userInitiated) {
                try RedirectsStore(sourceDirectory: sourceDirectory).save(entries)
            }.value
            savedRedirectEntries = entries
            return true
        } catch {
            redirectsError = "Couldn't save redirects: \(error.localizedDescription)"
            return false
        }
    }

    func setCloudflareAnalyticsEnabled(_ enabled: Bool) async {
        if !enabled {
            analyticsSettings.cloudflareToken = ""
            _ = await saveAnalytics()
            return
        }
        guard !isConfiguringCloudflareAnalytics else { return }
        isConfiguringCloudflareAnalytics = true
        analyticsError = nil
        defer { isConfiguringCloudflareAnalytics = false }

        do {
            guard let token = try await cloudflareToken(), !token.isEmpty else {
                analyticsError = CloudflareWebAnalyticsError.missingToken.localizedDescription
                return
            }
            let config = try WebsiteAnalyticsAsset.loadConfig(siteDirectory: sourceDirectory)
            let fallbackHost = "\(SiteSlug.derive(from: initialWebsiteTitle)).pages.dev"
            let host = WebsiteAnalyticsAsset.bestHost(from: config, fallback: fallbackHost)
            let siteTag = try await analyticsProvider.siteTag(for: host, apiToken: token)
            analyticsSettings.cloudflareToken = siteTag
            _ = await saveAnalytics()
        } catch {
            analyticsError = error.localizedDescription
        }
    }

    private static func loadAnalyticsSettings(sourceDirectory: URL) throws -> WebsiteAnalyticsAsset.Settings {
        let layoutURL = sourceDirectory.appendingPathComponent(WebsiteAnalyticsAsset.layoutRelativePath)
        let config = try WebsiteAnalyticsAsset.loadConfig(siteDirectory: sourceDirectory)
        guard FileManager.default.fileExists(atPath: layoutURL.path) else {
            return WebsiteAnalyticsAsset.parseMigratingLegacySettings(layoutSource: "", config: config)
        }
        let source = try String(contentsOf: layoutURL, encoding: .utf8)
        return WebsiteAnalyticsAsset.parseMigratingLegacySettings(layoutSource: source, config: config)
    }

    private func cloudflareToken() async throws -> String? {
        do {
            if let token = try keychain.readCloudflareToken(), !token.isEmpty {
                return token
            }
        } catch {
            if cloudflareEnvironmentToken() == nil {
                throw error
            }
            await LogCenter.shared.append(
                source: "analytics",
                stream: .stderr,
                text: "Could not read Cloudflare API token from Keychain; falling back to CLOUDFLARE_API_TOKEN."
            )
        }
        if let env = cloudflareEnvironmentToken() {
            await LogCenter.shared.append(
                source: "analytics",
                stream: .stderr,
                text: "Using CLOUDFLARE_API_TOKEN environment fallback for Cloudflare Analytics."
            )
            return env
        }
        return nil
    }

    private func cloudflareEnvironmentToken() -> String? {
        let token = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    private static func isWebsiteTitleEntry(_ entry: PlistDocumentIO.PlistEntry) -> Bool {
        entry.key == "AnglesiteDisplayName" || entry.key == "displayName"
    }

    func entriesForSaving() -> [PlistDocumentIO.PlistEntry] {
        var merged = allEntries.filter { !Self.isWebsiteTitleEntry($0) }
        merged.append(contentsOf: entries)
        return merged
    }
}
