import Foundation

/// Non-secret account coordinates plus the corresponding secret-store values for one POSSE run.
public struct POSSECredentials: Equatable, Sendable {
    public struct Mastodon: Equatable, Sendable {
        public let baseURL: URL
        public let accessToken: String

        public init(baseURL: URL, accessToken: String) {
            self.baseURL = baseURL
            self.accessToken = accessToken
        }
    }

    public struct Bluesky: Equatable, Sendable {
        public let pdsURL: URL
        public let identifier: String
        public let appPassword: String

        public init(pdsURL: URL, identifier: String, appPassword: String) {
            self.pdsURL = pdsURL
            self.identifier = identifier
            self.appPassword = appPassword
        }
    }

    public let mastodon: Mastodon?
    public let bluesky: Bluesky?

    public init(mastodon: Mastodon? = nil, bluesky: Bluesky? = nil) {
        self.mastodon = mastodon
        self.bluesky = bluesky
    }
}

public enum POSSECredentialResolver {
    public typealias Provider = @Sendable (_ siteID: String, _ configDirectory: URL) -> POSSECredentials

    /// Builds a provider backed by `Config/settings.plist` + the platform secret store. Environment
    /// variables are an automation/development fallback and never get persisted or logged.
    public static func provider(
        secretStore: any SecretStore = PlatformSecretStore.make(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Provider {
        { siteID, configDirectory in
            let settings = (try? SiteConfigStore.read(from: configDirectory)) ?? SiteSettings()

            let mastodonOrigin = nonBlank(settings.mastodonBaseURL)
                ?? nonBlank(environment["ANGLESITE_MASTODON_BASE_URL"])
            let mastodonToken = ((try? secretStore.read(
                account: SecretAccounts.mastodonAccessToken(siteID: siteID)
            )) ?? nil).flatMap(nonBlank)
                ?? nonBlank(environment["ANGLESITE_MASTODON_ACCESS_TOKEN"])
            let mastodon: POSSECredentials.Mastodon?
            if let mastodonOrigin, let baseURL = httpURL(mastodonOrigin), let mastodonToken {
                mastodon = .init(baseURL: baseURL, accessToken: mastodonToken)
            } else {
                mastodon = nil
            }

            let blueskyIdentifier = nonBlank(settings.blueskyIdentifier)
                ?? nonBlank(environment["ANGLESITE_BLUESKY_IDENTIFIER"])
            let blueskyPassword = ((try? secretStore.read(
                account: SecretAccounts.blueskyAppPassword(siteID: siteID)
            )) ?? nil).flatMap(nonBlank)
                ?? nonBlank(environment["ANGLESITE_BLUESKY_APP_PASSWORD"])
            let pdsString = nonBlank(settings.blueskyPDSURL)
                ?? nonBlank(environment["ANGLESITE_BLUESKY_PDS_URL"])
                ?? "https://bsky.social"
            let bluesky: POSSECredentials.Bluesky?
            if let blueskyIdentifier, let blueskyPassword, let pdsURL = httpURL(pdsString) {
                bluesky = .init(pdsURL: pdsURL, identifier: blueskyIdentifier, appPassword: blueskyPassword)
            } else {
                bluesky = nil
            }
            return POSSECredentials(mastodon: mastodon, bluesky: bluesky)
        }
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func httpURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}
