// Tests/AnglesiteCoreTests/SiteConfigFileTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct SiteConfigFileTests {
    @Test func appendsNewKey() {
        let out = SiteConfigFile.upsert([("BOOKING_PROVIDER", "cal")], into: "SITE_NAME=Acme\n")
        #expect(out == "SITE_NAME=Acme\nBOOKING_PROVIDER=cal\n")
    }

    @Test func replacesExistingKeyInPlace() {
        let out = SiteConfigFile.upsert([("BOOKING_PROVIDER", "calendly")],
                                        into: "BOOKING_PROVIDER=cal\nSITE_NAME=Acme\n")
        #expect(out == "BOOKING_PROVIDER=calendly\nSITE_NAME=Acme\n")
    }

    @Test func upsertIsIdempotent() {
        let once = SiteConfigFile.upsert([("K", "v")], into: "")
        let twice = SiteConfigFile.upsert([("K", "v")], into: once)
        #expect(once == twice)
    }

    @Test func unionsCSPDomainsWithoutDuplicates() {
        let out = SiteConfigFile.addCSPDomains(["app.cal.com", "app.cal.com"],
                                               into: "SCRIPT_ALLOW=existing.com\n")
        #expect(out == "SCRIPT_ALLOW=existing.com,app.cal.com\n")
    }

    @Test func cspUnionIsIdempotent() {
        let once = SiteConfigFile.addCSPDomains(["app.cal.com"], into: "")
        let twice = SiteConfigFile.addCSPDomains(["app.cal.com"], into: once)
        #expect(once == twice)
        #expect(twice == "SCRIPT_ALLOW=app.cal.com\n")
    }

    /// CRLF input must be normalized to LF: the output key is replaced and no \r appears.
    @Test func upsertNormalizesCRLF() {
        let crlf = "SITE_NAME=Acme\r\nBOOKING_PROVIDER=cal\r\n"
        let out = SiteConfigFile.upsert([("BOOKING_PROVIDER", "calendly")], into: crlf)
        #expect(!out.contains("\r"), "Output must not contain \\r after CRLF normalization")
        #expect(out.contains("BOOKING_PROVIDER=calendly"))
        #expect(out.contains("SITE_NAME=Acme"))
    }
}
