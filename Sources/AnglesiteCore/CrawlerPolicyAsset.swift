import Foundation

/// Reads/writes the `BLOCK_AI` and `CONTENT_SIGNALS` `.site-config` keys that
/// `Resources/Template/scripts/edge-artifacts.ts` consumes to generate `robots.txt` (#408, #693).
/// Follows the same "read whole `.site-config`, `SiteConfigFile.upsert`, write back" pattern as
/// `WebsiteAnalyticsAsset.install` — this asset owns no file of its own, just two keys in the
/// site's shared `.site-config`.
public enum CrawlerPolicyAsset {
    /// A Cloudflare Content Signals Policy sub-directive's value
    /// (https://blog.cloudflare.com/content-signals-policy/). `unset` means the site expresses no
    /// preference for that purpose — `edge-artifacts.ts`'s `normalizeContentSignal` omits it from
    /// the emitted `Content-Signal` directive entirely, it is never written as `key=unset`.
    public enum ContentSignalValue: String, Sendable, CaseIterable, Identifiable, Equatable {
        case unset
        case yes
        case no
        public var id: Self { self }
    }

    public struct Settings: Sendable, Equatable {
        public var blockAI: Bool
        public var search: ContentSignalValue
        public var aiInput: ContentSignalValue
        public var aiTrain: ContentSignalValue

        public init(
            blockAI: Bool = false,
            search: ContentSignalValue = .unset,
            aiInput: ContentSignalValue = .unset,
            aiTrain: ContentSignalValue = .unset
        ) {
            self.blockAI = blockAI
            self.search = search
            self.aiInput = aiInput
            self.aiTrain = aiTrain
        }
    }

    /// The three sub-directive keys `edge-artifacts.ts`'s `normalizeContentSignal` recognizes, in
    /// the order they're emitted. Any other key in a hand-edited `CONTENT_SIGNALS` value is dropped
    /// on the next save, matching the TS side's behavior of dropping unrecognized keys.
    private static let contentSignalKeys: [(key: String, keyPath: WritableKeyPath<Settings, ContentSignalValue>)] = [
        ("search", \.search),
        ("ai-input", \.aiInput),
        ("ai-train", \.aiTrain),
    ]

    public static func parseSettings(from config: String) -> Settings {
        let blockAI = (SiteConfigFile.value(forKey: "BLOCK_AI", in: config) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased() == "true"
        var settings = Settings(blockAI: blockAI)
        let raw = SiteConfigFile.value(forKey: "CONTENT_SIGNALS", in: config) ?? ""
        for part in raw.split(separator: ",") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let match = contentSignalKeys.first(where: { $0.key == pair[0] }) else { continue }
            // Only "yes"/"no" are ever written by edge-artifacts.ts; anything else (including a
            // hand-edited "unset") is treated the same as the key being absent.
            guard let value = ContentSignalValue(rawValue: String(pair[1])), value != .unset else { continue }
            settings[keyPath: match.keyPath] = value
        }
        return settings
    }

    public static func install(_ settings: Settings, siteDirectory: URL, fileManager: FileManager = .default) throws {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updatedConfig = SiteConfigFile.upsert([
            ("BLOCK_AI", settings.blockAI ? "true" : "false"),
            ("CONTENT_SIGNALS", contentSignalValue(for: settings)),
        ], into: config)
        guard updatedConfig != config else { return }
        try updatedConfig.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private static func contentSignalValue(for settings: Settings) -> String {
        contentSignalKeys
            .compactMap { key, keyPath -> String? in
                let value = settings[keyPath: keyPath]
                guard value != .unset else { return nil }
                return "\(key)=\(value.rawValue)"
            }
            .joined(separator: ", ")
    }
}
