import Foundation
import Testing
@testable import AnglesiteCore

@Suite("MTAStsPolicyAsset (#851)")
struct MTAStsPolicyAssetTests {
    @Test("parses settings, including a comma-separated MX list")
    func parseSettings() {
        let settings = MTAStsPolicyAsset.parseSettings(from: "MTA_STS_MODE=testing\nMTA_STS_MX=mx1.example.com,*.mail.example.net\nTLS_RPT_RUA=reports@example.com\n")
        #expect(settings == .init(mode: .testing, domain: "", mxHosts: "mx1.example.com\n*.mail.example.net", reportMailbox: "reports@example.com"))
    }

    @Test("normalizes valid RFC 8461 MX patterns and drops invalid values")
    func normalizeMX() {
        #expect(MTAStsPolicyAsset.normalizedMXList("MX1.Example.com., *.mail.example.net\nmx1.example.com, bad host, *.*.example.com") == ["mx1.example.com", "*.mail.example.net"])
        #expect(MTAStsPolicyAsset.normalizedMXList("mx.example.xn--p1ai") == ["mx.example.xn--p1ai"])
    }

    @Test("creates the required MTA-STS record plus optional TLS-RPT record")
    func dnsRecords() {
        let settings = MTAStsPolicyAsset.Settings(mode: .testing, domain: "example.com", mxHosts: "mx.example.com", reportMailbox: "reports@example.com")
        let records = MTAStsPolicyAsset.dnsRecords(for: "example.com", settings: settings)
        #expect(records.count == 2)
        #expect(records[0].name == "_mta-sts.example.com")
        #expect(records[0].content.starts(with: "v=STSv1; id=a"))
        #expect(records[0].content.hasSuffix(";"))
        #expect(records[1] == .init(name: "_smtp._tls.example.com", content: "v=TLSRPTv1; rua=mailto:reports@example.com"))
    }

    @Test("policy ID changes when the effective policy changes")
    func policyIDChanges() {
        let testing = MTAStsPolicyAsset.dnsRecords(for: "example.com", settings: .init(mode: .testing, mxHosts: "mx.example.com"))[0]
        let enforce = MTAStsPolicyAsset.dnsRecords(for: "example.com", settings: .init(mode: .enforce, mxHosts: "mx.example.com"))[0]
        #expect(testing.content != enforce.content)
    }

    @Test("install writes normalized settings while preserving unrelated config")
    func install() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "SITE_NAME=Acme\n".write(to: root.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        try MTAStsPolicyAsset.install(.init(mode: .enforce, domain: "Example.com", mxHosts: "MX.Example.com\n*.mail.example.net", reportMailbox: "reports@example.com"), siteDirectory: root)
        let config = try String(contentsOf: root.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(config.contains("SITE_NAME=Acme"))
        #expect(config.contains("MTA_STS_MODE=enforce"))
        #expect(config.contains("MTA_STS_DOMAIN=example.com"))
        #expect(config.contains("MTA_STS_MX=mx.example.com,*.mail.example.net"))
        #expect(config.contains("TLS_RPT_RUA=mailto:reports@example.com"))
    }
}
