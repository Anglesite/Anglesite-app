import AppIntents
import AnglesiteCore
import Foundation

// MARK: - Dialog formatting (pure, unit-testable)

public enum DomainDialogs {
    public static func recordsSummary(_ records: [DNSRecord], domain: String) -> String {
        if records.isEmpty { return "\(domain) has no DNS records." }
        let lines = records.map { record in
            "\(DNSRecordLabeler.label(for: record)): \(record.type) \(record.name) → \(record.content)"
        }
        return "\(domain) has \(records.count) DNS record\(records.count == 1 ? "" : "s"):\n" + lines.joined(separator: "\n")
    }
    public static func added(type: String, name: String, domain: String) -> String {
        "Added a \(type) record for \(name) on \(domain)."
    }
    public static func deleted(domain: String) -> String {
        "Deleted the DNS record from \(domain)."
    }
    public static func failed(reason: String, domain: String) -> String {
        "Couldn't finish that on \(domain): \(reason)."
    }
}

private func domainErrorMessage(_ error: DomainOperationError, domain: String) -> String {
    switch error {
    case .noToken:
        return "No Cloudflare API token found."
    case .zoneNotFound(let d):
        return "Zone not found for \"\(d)\"."
    case .cloudflare(let cfError):
        switch cfError {
        case .unauthorized: return "API token is unauthorized."
        case .http(let status): return "Cloudflare API returned HTTP \(status)."
        case .api(let message): return "Cloudflare API error: \(message)"
        case .malformedResponse: return "Unexpected response from Cloudflare API."
        }
    }
}

// MARK: - List DNS Records

public struct ListDNSRecordsIntent: AppIntent {
    public static let title: LocalizedStringResource = "List DNS Records"
    public static let description = IntentDescription("List the current DNS records for a domain.")

    @Parameter(title: "Domain") public var domain: String
    @Dependency private var ops: any DomainOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("List DNS records for \(\.$domain)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = DomainOperationsOverride.scoped ?? ops
        let dialog = await run(svc: svc)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    private func run(svc: any DomainOperationsService) async -> String {
        switch await svc.listRecords(domain: domain) {
        case .success(let records):
            return DomainDialogs.recordsSummary(records, domain: domain)
        case .failure(let error):
            return DomainDialogs.failed(reason: domainErrorMessage(error, domain: domain), domain: domain)
        }
    }
}

// MARK: - Add DNS Record

public struct AddDNSRecordIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add DNS Record"
    public static let description = IntentDescription(
        "Add a DNS record (TXT, CNAME, A, AAAA, or MX) to a domain."
    )

    @Parameter(title: "Domain") public var domain: String
    @Parameter(title: "Type", description: "TXT, CNAME, A, AAAA, or MX.") public var type: String
    @Parameter(title: "Name") public var name: String
    @Parameter(title: "Content") public var content: String
    @Parameter(title: "TTL", default: 1) public var ttl: Int
    @Parameter(title: "Priority", description: "Required for MX records — lower is a more preferred mail server.")
    public var priority: Int?
    @Dependency private var ops: any DomainOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add a \(\.$type) record to \(\.$domain)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = DomainOperationsOverride.scoped ?? ops
        if DomainOperationsOverride.scoped == nil {
            try await requestConfirmation(dialog: "Add a \(type) record for \(name) to \(domain)?")
        }
        let dialog = await run(svc: svc)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    private func run(svc: any DomainOperationsService) async -> String {
        switch await svc.addRecord(domain: domain, type: type, name: name, content: content, ttl: ttl, priority: priority) {
        case .success:
            return DomainDialogs.added(type: type, name: name, domain: domain)
        case .failure(let error):
            return DomainDialogs.failed(reason: domainErrorMessage(error, domain: domain), domain: domain)
        }
    }
}

// MARK: - Delete DNS Record

public struct DeleteDNSRecordIntent: AppIntent {
    public static let title: LocalizedStringResource = "Delete DNS Record"
    public static let description = IntentDescription(
        "Delete a DNS record from a domain by its record identifier."
    )

    @Parameter(title: "Domain") public var domain: String
    @Parameter(title: "Record ID", description: "From a prior List DNS Records call.") public var recordID: String
    @Dependency private var ops: any DomainOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Delete a DNS record from \(\.$domain)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = DomainOperationsOverride.scoped ?? ops
        if DomainOperationsOverride.scoped == nil {
            try await requestConfirmation(dialog: "Delete this DNS record from \(domain)? This can't be undone.")
        }
        let dialog = await run(svc: svc)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    private func run(svc: any DomainOperationsService) async -> String {
        switch await svc.deleteRecord(domain: domain, recordID: recordID) {
        case .success:
            return DomainDialogs.deleted(domain: domain)
        case .failure(let error):
            return DomainDialogs.failed(reason: domainErrorMessage(error, domain: domain), domain: domain)
        }
    }
}

// MARK: - Test-only helpers

extension ListDNSRecordsIntent {
    /// Drives `perform`'s dialog logic directly, bypassing the AppIntents `@Dependency` gate.
    /// Only callable when `DomainOperationsOverride.scoped` is bound.
    func performForTesting() async -> String {
        guard let svc = DomainOperationsOverride.scoped else {
            fatalError("performForTesting requires a bound DomainOperationsOverride.scoped")
        }
        return await run(svc: svc)
    }
}

extension AddDNSRecordIntent {
    /// Drives the add directly, bypassing the AppIntents `requestConfirmation` gate.
    /// Only callable when `DomainOperationsOverride.scoped` is bound.
    func applyForTesting() async -> String {
        guard let svc = DomainOperationsOverride.scoped else {
            fatalError("applyForTesting requires a bound DomainOperationsOverride.scoped")
        }
        return await run(svc: svc)
    }
}

extension DeleteDNSRecordIntent {
    /// Drives the delete directly, bypassing the AppIntents `requestConfirmation` gate.
    /// Only callable when `DomainOperationsOverride.scoped` is bound.
    func applyForTesting() async -> String {
        guard let svc = DomainOperationsOverride.scoped else {
            fatalError("applyForTesting requires a bound DomainOperationsOverride.scoped")
        }
        return await run(svc: svc)
    }
}
