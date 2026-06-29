/// Applies a `HardenPlan` via the Cloudflare write API, then re-reads state and re-audits.
/// Per-item failures do not abort the remaining items.
public struct HardenExecutor: Sendable {
    private let reader: any CloudflareReading
    private let writer: any CloudflareWriting

    public init(reader: any CloudflareReading, writer: any CloudflareWriting) {
        self.reader = reader
        self.writer = writer
    }

    public struct ItemFailure: Sendable {
        public let item: HardenPlanItem
        public let error: String
        public init(item: HardenPlanItem, error: String) {
            self.item = item
            self.error = error
        }
    }

    public struct Result: Sendable {
        public let appliedCount: Int
        public let failedItems: [ItemFailure]
        public let postAuditFindings: [AuditReport.Finding]
        public let auditError: String?

        public init(appliedCount: Int, failedItems: [ItemFailure],
                    postAuditFindings: [AuditReport.Finding], auditError: String? = nil) {
            self.appliedCount = appliedCount
            self.failedItems = failedItems
            self.postAuditFindings = postAuditFindings
            self.auditError = auditError
        }
    }

    public func execute(
        plan: HardenPlan,
        zoneID: String,
        domain: String,
        apiToken: String
    ) async -> Result {
        var applied = 0
        var failures: [ItemFailure] = []

        for item in plan.items {
            do {
                try await apply(item, zoneID: zoneID, domain: domain, apiToken: apiToken)
                applied += 1
            } catch {
                failures.append(.init(item: item, error: "\(error)"))
            }
        }

        let findings: [AuditReport.Finding]
        var auditErr: String?
        do {
            let freshState = try await reader.zoneState(zoneID: zoneID, apiToken: apiToken)
            let expectsMail = !freshState.mxRecords.isEmpty
                && !freshState.mxRecords.allSatisfy({ $0.trimmingCharacters(in: .whitespaces) == "." || $0.hasPrefix("0 .") })
            findings = SecurityAudit.evaluate(freshState, expectsMail: expectsMail)
        } catch {
            findings = []
            auditErr = "\(error)"
        }

        return Result(appliedCount: applied, failedItems: failures,
                      postAuditFindings: findings, auditError: auditErr)
    }

    private func apply(_ item: HardenPlanItem, zoneID: String, domain: String,
                        apiToken: String) async throws {
        switch item {
        case .enableDNSSEC:
            try await writer.enableDNSSEC(zoneID: zoneID, apiToken: apiToken)
        case .addCAARecord(let ca):
            try await writer.addDNSRecord(
                zoneID: zoneID,
                record: DNSRecordPayload(type: "CAA", name: domain,
                                         content: "0 issue \"\(ca)\""),
                apiToken: apiToken)
        case .enableAlwaysUseHTTPS:
            try await writer.setAlwaysUseHTTPS(zoneID: zoneID, enabled: true, apiToken: apiToken)
        case .enableHSTS(let maxAge, let subs, let preload):
            try await writer.setHSTS(zoneID: zoneID, maxAge: maxAge, includeSubdomains: subs,
                                     preload: preload, apiToken: apiToken)
        case .enableBotFightMode:
            try await writer.setBotFightMode(zoneID: zoneID, enabled: true, apiToken: apiToken)
        case .addNullMX:
            try await writer.addDNSRecord(
                zoneID: zoneID,
                record: DNSRecordPayload(type: "MX", name: domain, content: ".", priority: 0),
                apiToken: apiToken)
        case .addSPFRejectAll:
            try await writer.addDNSRecord(
                zoneID: zoneID,
                record: DNSRecordPayload(type: "TXT", name: domain, content: "v=spf1 -all"),
                apiToken: apiToken)
        case .addDMARCReject:
            try await writer.addDNSRecord(
                zoneID: zoneID,
                record: DNSRecordPayload(type: "TXT", name: "_dmarc.\(domain)",
                                         content: "v=DMARC1; p=reject"),
                apiToken: apiToken)
        case .addWAFRule(let desc, let expr, let action):
            try await writer.createWAFCustomRule(
                zoneID: zoneID,
                rule: WAFRulePayload(description: desc, expression: expr, action: action),
                apiToken: apiToken)
        }
    }
}
