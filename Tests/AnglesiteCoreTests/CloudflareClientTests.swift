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

@Test("resolveZoneID matches case-insensitively on the zone name")
func resolveZoneIDCaseInsensitive() async throws {
    let json = """
    {"success":true,"errors":[],"messages":[],"result":[{"id":"zone123","name":"example.com","status":"active"}]}
    """
    let client = HTTPCloudflareClient(transport: fakeTransport(["/zones?": (200, json)]))
    let id = try await client.resolveZoneID(domain: "Example.COM", apiToken: "t")
    #expect(id == "zone123")
}

@Test("a malformed JSON body surfaces as .malformedResponse")
func malformedBodyMaps() async {
    let client = HTTPCloudflareClient(transport: fakeTransport(["/zones?": (200, "not json")]))
    await #expect(throws: CloudflareError.malformedResponse) {
        _ = try await client.resolveZoneID(domain: "example.com", apiToken: "t")
    }
}

@Test("a 403 surfaces as .unauthorized")
func unauthorizedMaps() async {
    let client = HTTPCloudflareClient(transport: fakeTransport(["/zones?": (403, "{\"success\":false}")]))
    await #expect(throws: CloudflareError.unauthorized) {
        _ = try await client.resolveZoneID(domain: "example.com", apiToken: "bad")
    }
}

@Test("zoneState assembles DNSSEC, settings, and DNS records")
func zoneStateAssembles() async throws {
    let env = { (r: String) in "{\"success\":true,\"errors\":[],\"messages\":[],\"result\":\(r)}" }
    let routes: [String: (Int, String)] = [
        "/dnssec": (200, env("{\"status\":\"active\"}")),
        "/settings/ssl": (200, env("{\"id\":\"ssl\",\"value\":\"strict\"}")),
        "/settings/always_use_https": (200, env("{\"id\":\"always_use_https\",\"value\":\"on\"}")),
        "/settings/security_header": (200, env("{\"id\":\"security_header\",\"value\":{\"strict_transport_security\":{\"enabled\":true,\"max_age\":31536000,\"include_subdomains\":true,\"preload\":false}}}")),
        "/dns_records": (200, env("[{\"type\":\"CAA\",\"name\":\"example.com\",\"content\":\"0 issue \\\"letsencrypt.org\\\"\"},{\"type\":\"TXT\",\"name\":\"example.com\",\"content\":\"v=spf1 -all\"},{\"type\":\"TXT\",\"name\":\"_dmarc.example.com\",\"content\":\"v=DMARC1; p=reject\"}]")),
    ]
    let client = HTTPCloudflareClient(transport: fakeTransport(routes))
    let s = try await client.zoneState(zoneID: "z", apiToken: "t")
    #expect(s.dnssecActive)
    #expect(s.sslMode == "strict")
    #expect(s.alwaysUseHTTPS)
    #expect(s.hsts == CloudflareZoneState.HSTS(maxAge: 31536000, includeSubdomains: true, preload: false))
    #expect(s.caaRecords == ["0 issue \"letsencrypt.org\""])
    #expect(s.spfRecords == ["v=spf1 -all"])
    #expect(s.dmarcRecords == ["v=DMARC1; p=reject"])
    #expect(s.mxRecords.isEmpty)
}

@Test("HSTS disabled yields nil hsts")
func zoneStateHSTSDisabled() async throws {
    let env = { (r: String) in "{\"success\":true,\"errors\":[],\"messages\":[],\"result\":\(r)}" }
    let routes: [String: (Int, String)] = [
        "/dnssec": (200, env("{\"status\":\"disabled\"}")),
        "/settings/ssl": (200, env("{\"id\":\"ssl\",\"value\":\"full\"}")),
        "/settings/always_use_https": (200, env("{\"id\":\"always_use_https\",\"value\":\"off\"}")),
        "/settings/security_header": (200, env("{\"id\":\"security_header\",\"value\":{\"strict_transport_security\":{\"enabled\":false}}}")),
        "/dns_records": (200, env("[]")),
    ]
    let client = HTTPCloudflareClient(transport: fakeTransport(routes))
    let s = try await client.zoneState(zoneID: "z", apiToken: "t")
    #expect(!s.dnssecActive)
    #expect(s.hsts == nil)
    #expect(s.caaRecords.isEmpty)
}
