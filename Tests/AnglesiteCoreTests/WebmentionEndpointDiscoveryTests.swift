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

    @Test("Link header endpoint resolved relative to the redirected response URL")
    func linkHeaderRelativeAfterRedirect() async throws {
        let redirected = URL(string: "https://target.example/moved/post")!
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(
                headers: ["Link": "<../webmention>; rel=\"webmention\""],
                responseURL: redirected
            )
        )
        #expect(endpoint?.absoluteString == "https://target.example/webmention")
    }

    @Test("HTML: a data-rel decoy attribute does not shadow a later real rel=webmention element")
    func htmlDataRelDecoyDoesNotMatch() async throws {
        let html = """
        <a data-rel="webmention" href="/decoy">wrong</a>
        <a href="/correct" rel="webmention">right</a>
        """
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport(html: html))
        #expect(endpoint?.absoluteString == "https://target.example/correct")
    }

    @Test("a non-UTF-8 (Latin-1) page still discovers a real endpoint via the ISO Latin-1 fallback")
    func nonUTF8PageFallsBackToLatin1() async throws {
        // 0xE9 is Latin-1 "é" but is not valid as a lone UTF-8 byte (it signals a 3-byte UTF-8
        // lead byte with no continuation bytes following) — String(data:encoding:.utf8) returns
        // nil for this whole body, which without a fallback would look identical to "this page
        // declares no endpoint," even though the ASCII markup after the prose is perfectly valid.
        var bytes = Array("<p>Caf".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: Array(
            "</p><link href=\"https://target.example/wm-latin1\" rel=\"webmention\">".utf8
        ))
        let body = Data(bytes)
        #expect(String(data: body, encoding: .utf8) == nil) // sanity: this body really isn't valid UTF-8

        let nonUTF8Transport: WebmentionEndpointDiscovery.Transport = { _ in
            let http = HTTPURLResponse(url: self.target, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, http)
        }
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: nonUTF8Transport)
        #expect(endpoint?.absoluteString == "https://target.example/wm-latin1")
    }

    @Test("no endpoint declared returns nil")
    func noEndpoint() async throws {
        let html = "<html><body>No webmention here. <a href=\"/other\" rel=\"nofollow\">link</a></body></html>"
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport(html: html))
        #expect(endpoint == nil)
    }
}
