/// A computed set of Cloudflare hardening changes, ready for preview and opt-in application.
public struct HardenPlan: Sendable, Equatable {
    public let items: [HardenPlanItem]
    public var isEmpty: Bool { items.isEmpty }

    public init(items: [HardenPlanItem]) {
        self.items = items
    }

    public var summary: String {
        if items.isEmpty { return "Zone is fully hardened. No changes needed." }
        return items.map(\.description).joined(separator: "\n")
    }
}

/// A single hardening change to apply to a Cloudflare zone.
public enum HardenPlanItem: Sendable, Hashable, CustomStringConvertible {
    case enableDNSSEC
    case addCAARecord(ca: String)
    case enableAlwaysUseHTTPS
    case enableHSTS(maxAge: Int, includeSubdomains: Bool, preload: Bool)
    case enableBotFightMode
    case addNullMX
    case addSPFRejectAll
    case addDMARCReject
    case addWAFRule(description: String, expression: String, action: String)
    case enableSpeedBrain
    case enableZstandardCompression
    case enableECH
    case enablePageShieldMonitoring

    public var description: String {
        switch self {
        case .enableDNSSEC:
            return "+ Enable DNSSEC"
        case .addCAARecord(let ca):
            return "+ Add CAA record: 0 issue \"\(ca)\""
        case .enableAlwaysUseHTTPS:
            return "+ Enable Always Use HTTPS"
        case .enableHSTS(let maxAge, let subs, let preload):
            var parts = "max-age=\(maxAge)"
            if subs { parts += "; includeSubDomains" }
            if preload { parts += "; preload" }
            return "+ Enable HSTS (\(parts))"
        case .enableBotFightMode:
            return "+ Enable Bot Fight Mode"
        case .addNullMX:
            return "+ Add null MX record (0 .)"
        case .addSPFRejectAll:
            return "+ Add SPF record: v=spf1 -all"
        case .addDMARCReject:
            return "+ Add DMARC record: v=DMARC1; p=reject"
        case .addWAFRule(let desc, _, let action):
            return "+ Add WAF rule [\(action)]: \(desc)"
        case .enableSpeedBrain:
            return "+ Enable Speed Brain (speculative prefetching)"
        case .enableZstandardCompression:
            return "+ Enable Zstandard compression"
        case .enableECH:
            return "+ Enable Encrypted Client Hello (ECH)"
        case .enablePageShieldMonitoring:
            return "+ Enable client-side script monitoring (Page Shield)"
        }
    }
}
