import Testing
@testable import AnglesiteCore

struct HardenPlannerTests {
    private func hardened() -> CloudflareZoneState {
        CloudflareZoneState(
            dnssecActive: true, sslMode: "strict", alwaysUseHTTPS: true,
            hsts: .init(maxAge: 31_536_000, includeSubdomains: true, preload: false),
            caaRecords: [
                "0 issue \"letsencrypt.org\"",
                "0 issue \"digicert.com\"",
                "0 issue \"pki.goog\"",
            ],
            mxRecords: ["0 ."], spfRecords: ["v=spf1 -all"],
            dmarcRecords: ["v=DMARC1; p=reject"],
            botFightMode: true,
            wafCustomRules: HardenPlanner.curatedWAFRules.map {
                .init(description: $0.description, expression: $0.expression, action: $0.action)
            })
    }

    private func bare() -> CloudflareZoneState {
        CloudflareZoneState(
            dnssecActive: false, sslMode: "flexible", alwaysUseHTTPS: false,
            hsts: nil, caaRecords: [], mxRecords: [],
            spfRecords: [], dmarcRecords: [])
    }

    @Test("a fully hardened zone produces an empty plan")
    func fullyHardenedIsEmpty() {
        let plan = HardenPlanner.plan(from: hardened(), domain: "example.com")
        #expect(plan.isEmpty)
        #expect(plan.summary.contains("No changes needed"))
    }

    @Test("a bare zone produces items for every hardening category")
    func bareProducesAllItems() {
        let plan = HardenPlanner.plan(from: bare(), domain: "example.com")
        #expect(!plan.isEmpty)
        #expect(plan.items.contains(.enableDNSSEC))
        #expect(plan.items.contains(.enableAlwaysUseHTTPS))
        #expect(plan.items.contains(.enableBotFightMode))
        #expect(plan.items.contains(.addNullMX))
        #expect(plan.items.contains(.addSPFRejectAll))
        #expect(plan.items.contains(.addDMARCReject))
        #expect(plan.items.contains(where: { if case .enableHSTS = $0 { return true }; return false }))
        let caaItems = plan.items.filter { if case .addCAARecord = $0 { return true }; return false }
        #expect(caaItems.count == 3)
        let wafItems = plan.items.filter { if case .addWAFRule = $0 { return true }; return false }
        #expect(wafItems.count == HardenPlanner.curatedWAFRules.count)
    }

    @Test("only missing CAA CAs are added")
    func partialCAAOnlyAddsMissing() {
        var s = hardened()
        s.caaRecords = ["0 issue \"letsencrypt.org\""]
        let plan = HardenPlanner.plan(from: s, domain: "example.com")
        let cas = plan.items.compactMap { if case .addCAARecord(let ca) = $0 { return ca }; return nil }
        #expect(cas.count == 2)
        #expect(cas.contains("digicert.com"))
        #expect(cas.contains("pki.goog"))
        #expect(!cas.contains("letsencrypt.org"))
    }

    @Test("HSTS with short max-age triggers enableHSTS")
    func shortHSTSTriggersItem() {
        var s = hardened()
        s.hsts = .init(maxAge: 3600, includeSubdomains: false, preload: false)
        let plan = HardenPlanner.plan(from: s, domain: "example.com")
        #expect(plan.items.contains(where: { if case .enableHSTS = $0 { return true }; return false }))
    }

    @Test("a mail-sending domain skips email hardening")
    func mailDomainSkipsEmail() {
        var s = bare()
        s.mxRecords = ["10 mail.example.com"]
        let plan = HardenPlanner.plan(from: s, domain: "example.com")
        #expect(!plan.items.contains(.addNullMX))
        #expect(!plan.items.contains(.addSPFRejectAll))
        #expect(!plan.items.contains(.addDMARCReject))
    }

    @Test("existing WAF rules are not duplicated")
    func wafRulesDeduped() {
        var s = bare()
        s.wafCustomRules = [.init(description: "Block path traversal attempts", expression: "x", action: "block")]
        let plan = HardenPlanner.plan(from: s, domain: "example.com")
        let wafDescs = plan.items.compactMap { if case .addWAFRule(let d, _, _) = $0 { return d }; return nil }
        #expect(!wafDescs.contains("Block path traversal attempts"))
        #expect(wafDescs.count == HardenPlanner.curatedWAFRules.count - 1)
    }

    @Test("WAF dedup is case-insensitive")
    func wafDedupCaseInsensitive() {
        var s = bare()
        s.wafCustomRules = [.init(description: "BLOCK PATH TRAVERSAL ATTEMPTS", expression: "x", action: "block")]
        let plan = HardenPlanner.plan(from: s, domain: "example.com")
        let wafDescs = plan.items.compactMap { if case .addWAFRule(let d, _, _) = $0 { return d }; return nil }
        #expect(!wafDescs.contains("Block path traversal attempts"))
    }

    @Test("plan summary is non-empty for a non-empty plan")
    func summaryNonEmpty() {
        let plan = HardenPlanner.plan(from: bare(), domain: "example.com")
        #expect(!plan.summary.isEmpty)
        #expect(plan.summary.contains("+"))
    }

    @Test("SPF with -all already present is not duplicated")
    func existingSPFNotDuped() {
        var s = bare()
        s.spfRecords = ["v=spf1 -all"]
        let plan = HardenPlanner.plan(from: s, domain: "example.com")
        #expect(!plan.items.contains(.addSPFRejectAll))
        #expect(plan.items.contains(.addNullMX))
    }

    @Test("SPF with ~all (softfail) still triggers addSPFRejectAll")
    func softfailSPFTriggersHarden() {
        var s = bare()
        s.spfRecords = ["v=spf1 ~all"]
        let plan = HardenPlanner.plan(from: s, domain: "example.com")
        #expect(plan.items.contains(.addSPFRejectAll))
    }

    @Test("DMARC with sp=reject but no p=reject still triggers addDMARCReject")
    func dmarcSubdomainPolicyNotConfused() {
        var s = bare()
        s.dmarcRecords = ["v=DMARC1; sp=reject"]
        let plan = HardenPlanner.plan(from: s, domain: "example.com")
        #expect(plan.items.contains(.addDMARCReject))
    }

    @Test("DMARC with p=reject is recognized regardless of position")
    func dmarcPolicyRecognized() {
        var s = bare()
        s.dmarcRecords = ["v=DMARC1; sp=none; p=reject; rua=mailto:x@example.com"]
        let plan = HardenPlanner.plan(from: s, domain: "example.com")
        #expect(!plan.items.contains(.addDMARCReject))
    }
}
