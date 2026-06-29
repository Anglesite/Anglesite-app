import Foundation

/// A read-only snapshot of a Cloudflare zone's security-relevant edge/DNS state.
/// Assembled by `HTTPCloudflareClient.zoneState` and graded by `SecurityAudit`.
public struct CloudflareZoneState: Sendable, Equatable {
    /// HSTS edge setting (Zone Settings → security_header). `nil` when disabled.
    public struct HSTS: Sendable, Equatable {
        public var maxAge: Int
        public var includeSubdomains: Bool
        public var preload: Bool
        public init(maxAge: Int, includeSubdomains: Bool, preload: Bool) {
            self.maxAge = maxAge
            self.includeSubdomains = includeSubdomains
            self.preload = preload
        }
    }

    public var dnssecActive: Bool
    /// SSL/TLS encryption mode: "off" | "flexible" | "full" | "strict".
    public var sslMode: String
    public var alwaysUseHTTPS: Bool
    public var hsts: HSTS?
    /// Raw record contents (`content` field) for the relevant DNS types.
    public var caaRecords: [String]
    public var mxRecords: [String]
    /// TXT records whose content starts with `v=spf1`.
    public var spfRecords: [String]
    /// TXT records at `_dmarc.<zone>` whose content starts with `v=DMARC1`.
    public var dmarcRecords: [String]

    public init(dnssecActive: Bool, sslMode: String, alwaysUseHTTPS: Bool, hsts: HSTS?,
                caaRecords: [String], mxRecords: [String], spfRecords: [String], dmarcRecords: [String]) {
        self.dnssecActive = dnssecActive
        self.sslMode = sslMode
        self.alwaysUseHTTPS = alwaysUseHTTPS
        self.hsts = hsts
        self.caaRecords = caaRecords
        self.mxRecords = mxRecords
        self.spfRecords = spfRecords
        self.dmarcRecords = dmarcRecords
    }
}
