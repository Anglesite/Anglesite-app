import Testing
@testable import AnglesiteCore

@Suite("CloudflareWebAnalyticsClient")
struct CloudflareWebAnalyticsClientTests {
    @Test("matchingSite normalizes host URLs")
    func matchingSiteNormalizesHostURLs() {
        let sites = [
            CloudflareWebAnalyticsSite(host: "example.com", siteTag: "tag-1"),
            CloudflareWebAnalyticsSite(host: "other.example", siteTag: "tag-2")
        ]

        #expect(CloudflareWebAnalyticsClient.matchingSite(for: "https://example.com/", in: sites)?.siteTag == "tag-1")
        #expect(CloudflareWebAnalyticsClient.matchingSite(for: "OTHER.EXAMPLE/path", in: sites)?.siteTag == "tag-2")
        #expect(CloudflareWebAnalyticsClient.matchingSite(for: "missing.example", in: sites) == nil)
    }
}
