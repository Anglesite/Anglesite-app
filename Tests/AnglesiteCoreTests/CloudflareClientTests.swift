import Testing
import Foundation
@testable import AnglesiteCore

struct CloudflareClientTests {
    @Test("CloudflareZoneState is value-equal by field")
    func zoneStateEquatable() {
        let a = CloudflareZoneState(
            dnssecActive: true, sslMode: "strict", alwaysUseHTTPS: true,
            hsts: .init(maxAge: 31_536_000, includeSubdomains: true, preload: false),
            caaRecords: ["0 issue \"letsencrypt.org\""], mxRecords: [],
            spfRecords: ["v=spf1 -all"], dmarcRecords: ["v=DMARC1; p=reject"])
        let b = a
        #expect(a == b)
    }
}

/// A fake transport that routes by URL substring to canned (Data, HTTPURLResponse).
func fakeTransport(_ routes: [String: (Int, String)]) -> CloudflareTransport {
    return { request in
        let url = request.url!.absoluteString
        for (needle, pair) in routes where url.contains(needle) {
            let resp = HTTPURLResponse(url: request.url!, statusCode: pair.0,
                                       httpVersion: nil, headerFields: nil)!
            return (Data(pair.1.utf8), resp)
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        return (Data("{\"success\":false}".utf8), resp)
    }
}

@Test("resolveZoneID returns the id of the matching active zone")
func resolveZoneIDFound() async throws {
    let json = """
    {"success":true,"errors":[],"messages":[],"result":[{"id":"zone123","name":"example.com","status":"active"}]}
    """
    let client = HTTPCloudflareClient(transport: fakeTransport(["/zones?": (200, json)]))
    let id = try await client.resolveZoneID(domain: "example.com", apiToken: "t")
    #expect(id == "zone123")
}

@Test("resolveZoneID returns nil when no zone matches")
func resolveZoneIDMissing() async throws {
    let json = "{\"success\":true,\"errors\":[],\"messages\":[],\"result\":[]}"
    let client = HTTPCloudflareClient(transport: fakeTransport(["/zones?": (200, json)]))
    let id = try await client.resolveZoneID(domain: "absent.com", apiToken: "t")
    #expect(id == nil)
}

@Test("a 403 surfaces as .unauthorized")
func unauthorizedMaps() async {
    let client = HTTPCloudflareClient(transport: fakeTransport(["/zones?": (403, "{\"success\":false}")]))
    await #expect(throws: CloudflareError.unauthorized) {
        _ = try await client.resolveZoneID(domain: "example.com", apiToken: "bad")
    }
}
