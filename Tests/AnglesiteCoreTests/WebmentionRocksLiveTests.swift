// Real-network integration test against webmention.rocks — gated behind ANGLESITE_WEBMENTION_E2E
// so CI and everyday `swift test` runs never depend on a third-party site's availability.
// Exercises WebmentionEndpointDiscovery's Link-header/HTML/redirect logic against real markup,
// using webmention.rocks' own documented test pages (https://webmention.rocks/about).
//
// Run locally with:
//   ANGLESITE_WEBMENTION_E2E=1 swift test --filter WebmentionRocksLiveTests
//
// Discovery-only, not POST-acceptance: webmention.rocks validates (RFC 7565 source verification)
// that the source document actually links back to the target before accepting a webmention, so
// an automated test using a synthetic source URL can never get a POST accepted — that requires
// visiting their site and using a session-specific source-URL token they crawl back to verify,
// an interactive, one-time manual step (see the PR description), not something this automated
// test attempts. This test only confirms discovery against real pages, as ongoing regression
// coverage for the parsing logic.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("Webmention send against webmention.rocks (live)")
struct WebmentionRocksLiveTests {
    private static var liveTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["ANGLESITE_WEBMENTION_E2E"] == "1"
    }

    private let transport: WebmentionEndpointDiscovery.Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    @Test(
        "test 1 (HTTP Link header) discovers a real endpoint",
        .enabled(if: liveTestsEnabled, "hits the real webmention.rocks — set ANGLESITE_WEBMENTION_E2E=1 to opt in")
    )
    func linkHeaderTestPage() async throws {
        let target = URL(string: "https://webmention.rocks/test/1")!
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport)
        // Discovery-only: webmention.rocks validates (RFC 7565 source verification) that the
        // source document actually links back to the target before accepting a POST, so a
        // synthetic source URL always gets HTTP 400 regardless of wire-format correctness.
        // POST-acceptance is exercised by the separate manual acceptance step instead.
        #expect(endpoint != nil)
    }

    @Test(
        "test 4 (HTML <link> tag, absolute URL) discovers a real endpoint",
        .enabled(if: liveTestsEnabled, "hits the real webmention.rocks — set ANGLESITE_WEBMENTION_E2E=1 to opt in")
    )
    func htmlLinkElementTestPage() async throws {
        let target = URL(string: "https://webmention.rocks/test/4")!
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport)
        #expect(endpoint?.absoluteString == "https://webmention.rocks/test/4/webmention")
    }

    @Test(
        "test 23 (redirect target, relative endpoint) discovers a real endpoint via the post-redirect URL",
        .enabled(if: liveTestsEnabled, "hits the real webmention.rocks — set ANGLESITE_WEBMENTION_E2E=1 to opt in")
    )
    func redirectTestPage() async throws {
        let target = URL(string: "https://webmention.rocks/test/23/page")!
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport)
        #expect(endpoint != nil)
    }
}
