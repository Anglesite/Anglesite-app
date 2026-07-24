import Testing
@testable import AnglesiteCore

@Suite("SecretAccounts")
struct SecretAccountsTests {
    @Test("activityPubPrivateKeyPem is namespaced per site, matching the mastodonAccessToken pattern")
    func activityPubPrivateKeyPemIsPerSite() {
        let a = SecretAccounts.activityPubPrivateKeyPem(siteID: "site-a")
        let b = SecretAccounts.activityPubPrivateKeyPem(siteID: "site-b")
        #expect(a != b)
        #expect(a.contains("site-a"))
    }

    @Test("activityPubPublishToken is namespaced per site and distinct from the private key account")
    func activityPubPublishTokenIsPerSiteAndDistinct() {
        let token = SecretAccounts.activityPubPublishToken(siteID: "site-a")
        let key = SecretAccounts.activityPubPrivateKeyPem(siteID: "site-a")
        #expect(token != key)
        #expect(token.contains("site-a"))
    }
}
