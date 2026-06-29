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
/// Routes are matched longest-needle-first so more specific paths win over prefixes.
func fakeTransport(_ routes: [String: (Int, String)]) -> CloudflareTransport {
    let sorted = routes.sorted { $0.key.count > $1.key.count }
    return { request in
        let url = request.url!.absoluteString
        for (needle, pair) in sorted where url.contains(needle) {
            let resp = HTTPURLResponse(url: request.url!, statusCode: pair.0,
                                       httpVersion: nil, headerFields: nil)!
            return (Data(pair.1.utf8), resp)
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        return (Data("{\"success\":false}".utf8), resp)
    }
}

/// Thread-safe spy that records requests for write-method assertions.
final class TransportSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        _requests.append(request)
    }
}

/// A method-aware fake transport with optional spy for capturing requests.
/// Routes are matched longest-needle-first so more specific paths win over prefixes.
func spyTransport(_ routes: [String: (Int, String)], spy: TransportSpy? = nil) -> CloudflareTransport {
    let sorted = routes.sorted { $0.key.count > $1.key.count }
    return { request in
        spy?.record(request)
        let url = request.url!.absoluteString
        for (needle, pair) in sorted where url.contains(needle) {
            let resp = HTTPURLResponse(url: request.url!, statusCode: pair.0,
                                       httpVersion: nil, headerFields: nil)!
            return (Data(pair.1.utf8), resp)
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("{\"success\":true,\"errors\":[],\"result\":{}}".utf8), resp)
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

@Test("zoneState assembles DNSSEC, settings, DNS records, bot mode, and WAF rules")
func zoneStateAssembles() async throws {
    let env = { (r: String) in "{\"success\":true,\"errors\":[],\"messages\":[],\"result\":\(r)}" }
    let routes: [String: (Int, String)] = [
        "/dnssec": (200, env("{\"status\":\"active\"}")),
        "/settings/ssl": (200, env("{\"id\":\"ssl\",\"value\":\"strict\"}")),
        "/settings/always_use_https": (200, env("{\"id\":\"always_use_https\",\"value\":\"on\"}")),
        "/settings/security_header": (200, env("{\"id\":\"security_header\",\"value\":{\"strict_transport_security\":{\"enabled\":true,\"max_age\":31536000,\"include_subdomains\":true,\"preload\":false}}}")),
        "/dns_records": (200, env("[{\"type\":\"CAA\",\"name\":\"example.com\",\"content\":\"0 issue \\\"letsencrypt.org\\\"\"},{\"type\":\"TXT\",\"name\":\"example.com\",\"content\":\"v=spf1 -all\"},{\"type\":\"TXT\",\"name\":\"_dmarc.example.com\",\"content\":\"v=DMARC1; p=reject\"}]")),
        "/settings/bot_management": (200, env("{\"fight_mode\":true}")),
        "/rulesets/rs1": (200, env("{\"id\":\"rs1\",\"phase\":\"http_request_firewall_custom\",\"rules\":[{\"description\":\"Block dotfiles\",\"expression\":\"(x)\",\"action\":\"block\"}]}")),
        "/rulesets": (200, env("[{\"id\":\"rs1\",\"phase\":\"http_request_firewall_custom\"}]")),
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
    #expect(s.botFightMode)
    #expect(s.wafCustomRules.count == 1)
    #expect(s.wafCustomRules.first?.description == "Block dotfiles")
}

@Test("HSTS disabled yields nil hsts; bot fight mode gracefully defaults on error")
func zoneStateHSTSDisabled() async throws {
    let env = { (r: String) in "{\"success\":true,\"errors\":[],\"messages\":[],\"result\":\(r)}" }
    let routes: [String: (Int, String)] = [
        "/dnssec": (200, env("{\"status\":\"disabled\"}")),
        "/settings/ssl": (200, env("{\"id\":\"ssl\",\"value\":\"full\"}")),
        "/settings/always_use_https": (200, env("{\"id\":\"always_use_https\",\"value\":\"off\"}")),
        "/settings/security_header": (200, env("{\"id\":\"security_header\",\"value\":{\"strict_transport_security\":{\"enabled\":false}}}")),
        "/dns_records": (200, env("[]")),
        "/rulesets": (200, env("[]")),
    ]
    let client = HTTPCloudflareClient(transport: fakeTransport(routes))
    let s = try await client.zoneState(zoneID: "z", apiToken: "t")
    #expect(!s.dnssecActive)
    #expect(s.hsts == nil)
    #expect(s.caaRecords.isEmpty)
    #expect(!s.botFightMode)
    #expect(s.wafCustomRules.isEmpty)
}
