import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WebmentionEndpointDiscovery")
struct WebmentionEndpointDiscoveryTests {
    private let target = URL(string: "https://target.example/post")!

    private func transport(
        status: Int = 200,
        headers: [String: String] = [:],
        html: String = "",
        responseURL: URL? = nil
    ) -> WebmentionEndpointDiscovery.Transport {
        let url = responseURL ?? target
        return { _ in
            let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(html.utf8), http)
        }
    }

    @Test("discovers via a simple Link header")
    func linkHeaderSimple() async throws {
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(headers: ["Link": "<https://target.example/webmention>; rel=\"webmention\""])
        )
        #expect(endpoint?.absoluteString == "https://target.example/webmention")
    }

    @Test("Link header: webmention rel among multiple link-values")
    func linkHeaderMultipleValues() async throws {
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(headers: [
                "Link": "<https://target.example/pgp>; rel=\"pgp-key\", <https://target.example/wm>; rel=\"webmention\"",
            ])
        )
        #expect(endpoint?.absoluteString == "https://target.example/wm")
    }

    @Test("Link header: unquoted rel value")
    func linkHeaderUnquotedRel() async throws {
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(headers: ["Link": "</test/1/webmention?head=true>; rel=webmention"])
        )
        #expect(endpoint?.absoluteString == "https://target.example/test/1/webmention?head=true")
    }

    @Test("Link header: legacy rel=\"http://webmention.org/\" form")
    func linkHeaderLegacyRel() async throws {
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(headers: ["Link": "<https://target.example/wm>; rel=\"http://webmention.org/\""])
        )
        #expect(endpoint?.absoluteString == "https://target.example/wm")
    }

    @Test("Link header endpoint relative to the response URL")
    func linkHeaderRelative() async throws {
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(headers: ["Link": "</webmention-endpoint>; rel=\"webmention\""])
        )
        #expect(endpoint?.absoluteString == "https://target.example/webmention-endpoint")
    }

    @Test("falls back to an HTML <link rel=webmention> element")
    func htmlLinkElement() async throws {
        let html = """
        <html><head><link rel="stylesheet" href="/style.css">
        <link href="https://target.example/wm-html" rel="webmention"></head></html>
        """
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport(html: html))
        #expect(endpoint?.absoluteString == "https://target.example/wm-html")
    }

    @Test("falls back to an HTML <a rel=webmention> element")
    func htmlAnchorElement() async throws {
        let html = """
        <html><body><a href="https://target.example/wm-a" rel="webmention">webmention</a></body></html>
        """
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport(html: html))
        #expect(endpoint?.absoluteString == "https://target.example/wm-a")
    }

    @Test("HTML: first webmention element in document order wins")
    func htmlDocumentOrder() async throws {
        let html = """
        <html><head><link rel="webmention" href="https://target.example/first"></head>
        <body><a href="https://target.example/second" rel="webmention">webmention</a></body></html>
        """
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport(html: html))
        #expect(endpoint?.absoluteString == "https://target.example/first")
    }

    @Test("HTML endpoint resolved relative to the redirected response URL")
    func htmlRelativeAfterRedirect() async throws {
        let redirected = URL(string: "https://target.example/moved/post")!
        let html = "<link rel=\"webmention\" href=\"../webmention\">"
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(html: html, responseURL: redirected)
        )
        #expect(endpoint?.absoluteString == "https://target.example/webmention")
    }

    @Test("no endpoint declared returns nil")
    func noEndpoint() async throws {
        let html = "<html><body>No webmention here. <a href=\"/other\" rel=\"nofollow\">link</a></body></html>"
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport(html: html))
        #expect(endpoint == nil)
    }
}
