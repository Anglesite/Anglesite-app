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
