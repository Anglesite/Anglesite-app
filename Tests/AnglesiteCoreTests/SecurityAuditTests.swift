import Testing
@testable import AnglesiteCore

struct SecurityAuditTests {
    private func clean() -> CloudflareZoneState {
        CloudflareZoneState(
            dnssecActive: true, sslMode: "strict", alwaysUseHTTPS: true,
            hsts: .init(maxAge: 31_536_000, includeSubdomains: true, preload: false),
            caaRecords: ["0 issue \"letsencrypt.org\""], mxRecords: [],
            spfRecords: ["v=spf1 -all"], dmarcRecords: ["v=DMARC1; p=reject"],
            botFightMode: true)
    }

    @Test("a fully hardened non-mail zone yields no findings")
    func cleanZoneNoFindings() {
        #expect(SecurityAudit.evaluate(clean(), expectsMail: false).isEmpty)
    }

    @Test("DNSSEC disabled is a warning")
    func dnssecWarning() {
        var s = clean(); s.dnssecActive = false
        let f = SecurityAudit.evaluate(s, expectsMail: false)
        #expect(f.contains { $0.severity == .warning && $0.title.contains("DNSSEC") })
    }

    @Test("weak SSL mode is critical")
    func sslCritical() {
        var s = clean(); s.sslMode = "flexible"
        let f = SecurityAudit.evaluate(s, expectsMail: false)
        #expect(f.contains { $0.severity == .critical && $0.title.contains("SSL") })
    }

    @Test("missing HSTS and Always-Use-HTTPS each warn")
    func httpsWarnings() {
        var s = clean(); s.hsts = nil; s.alwaysUseHTTPS = false
        let f = SecurityAudit.evaluate(s, expectsMail: false)
        #expect(f.contains { $0.title.contains("HSTS") })
        #expect(f.contains { $0.title.contains("HTTPS") })
    }

    @Test("missing CAA is an info finding")
    func caaInfo() {
        var s = clean(); s.caaRecords = []
        let f = SecurityAudit.evaluate(s, expectsMail: false)
        #expect(f.contains { $0.severity == .info && $0.title.contains("CAA") })
    }

    @Test("non-mail zone without SPF -all / DMARC reject warns on spoofing")
    func emailWarnings() {
        var s = clean(); s.spfRecords = []; s.dmarcRecords = []
        let f = SecurityAudit.evaluate(s, expectsMail: false)
        #expect(f.contains { $0.title.contains("SPF") })
        #expect(f.contains { $0.title.contains("DMARC") })
    }

    @Test("a mail-sending zone is not warned for absent SPF/DMARC by this audit")
    func mailZoneSkipsEmailHardening() {
        var s = clean(); s.spfRecords = []; s.dmarcRecords = []
        let f = SecurityAudit.evaluate(s, expectsMail: true)
        #expect(!f.contains { $0.title.contains("SPF") })
    }

    @Test("Bot Fight Mode off is an info finding")
    func botFightModeInfo() {
        var s = clean(); s.botFightMode = false
        let f = SecurityAudit.evaluate(s, expectsMail: false)
        #expect(f.contains { $0.severity == .info && $0.title.contains("Bot Fight Mode") })
    }

    @Test("every finding is in the security category")
    func allSecurityCategory() {
        var s = clean(); s.dnssecActive = false; s.sslMode = "off"
        #expect(SecurityAudit.evaluate(s, expectsMail: false).allSatisfy { $0.category == .security })
    }
}
