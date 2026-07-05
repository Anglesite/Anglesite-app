import Foundation

/// Errors surfaced by `DomainOperationsService`. `.cloudflare` wraps the underlying
/// `CloudflareError` for callers that want the detailed reason (e.g. to render the same
/// messages `HardenModel` shows for its own Cloudflare calls).
public enum DomainOperationError: Error, Equatable, Sendable {
    case noToken
    case zoneNotFound(domain: String)
    case cloudflare(CloudflareError)
}

/// Domain/DNS operations for a site's Cloudflare-managed zone: list, add, and delete DNS
/// records. Centralizes token lookup and zone resolution so `DomainModel` (GUI) and the
/// `AnglesiteIntents` Domain intents (Siri) share one implementation, mirroring how
/// `IntegrationOperationsService` backs both `IntegrationWizardModel` and `IntegrationIntents`.
public protocol DomainOperationsService: Sendable {
    func listRecords(domain: String) async -> Result<[DNSRecord], DomainOperationError>
    func addRecord(domain: String, type: String, name: String, content: String, ttl: Int) async -> Result<Void, DomainOperationError>
    func deleteRecord(domain: String, recordID: String) async -> Result<Void, DomainOperationError>
}

public struct DomainOperations: DomainOperationsService {
    private let reader: any CloudflareReading
    private let writer: any CloudflareWriting
    private let tokenProvider: @Sendable () -> String?

    public init(
        reader: any CloudflareReading = HTTPCloudflareClient(),
        writer: any CloudflareWriting = HTTPCloudflareClient(),
        tokenProvider: @escaping @Sendable () -> String? = DomainOperations.defaultTokenProvider
    ) {
        self.reader = reader
        self.writer = writer
        self.tokenProvider = tokenProvider
    }

    /// Env var first (matches `HardenModel.apiToken()`), then the Keychain-stored token.
    public static let defaultTokenProvider: @Sendable () -> String? = {
        if let env = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"], !env.isEmpty {
            return env
        }
        return try? KeychainStore().readCloudflareToken()
    }

    private func resolveZone(domain: String, token: String) async -> Result<String, DomainOperationError> {
        do {
            guard let zoneID = try await reader.resolveZoneID(domain: domain, apiToken: token) else {
                return .failure(.zoneNotFound(domain: domain))
            }
            return .success(zoneID)
        } catch let error as CloudflareError {
            return .failure(.cloudflare(error))
        } catch {
            return .failure(.cloudflare(.malformedResponse))
        }
    }

    public func listRecords(domain: String) async -> Result<[DNSRecord], DomainOperationError> {
        guard let token = tokenProvider() else { return .failure(.noToken) }
        switch await resolveZone(domain: domain, token: token) {
        case .failure(let error):
            return .failure(error)
        case .success(let zoneID):
            do {
                return .success(try await reader.listDNSRecords(zoneID: zoneID, apiToken: token))
            } catch let error as CloudflareError {
                return .failure(.cloudflare(error))
            } catch {
                return .failure(.cloudflare(.malformedResponse))
            }
        }
    }

    public func addRecord(domain: String, type: String, name: String, content: String, ttl: Int) async -> Result<Void, DomainOperationError> {
        guard let token = tokenProvider() else { return .failure(.noToken) }
        switch await resolveZone(domain: domain, token: token) {
        case .failure(let error):
            return .failure(error)
        case .success(let zoneID):
            do {
                let payload = DNSRecordPayload(type: type, name: name, content: content, ttl: ttl)
                try await writer.addDNSRecord(zoneID: zoneID, record: payload, apiToken: token)
                return .success(())
            } catch let error as CloudflareError {
                return .failure(.cloudflare(error))
            } catch {
                return .failure(.cloudflare(.malformedResponse))
            }
        }
    }

    public func deleteRecord(domain: String, recordID: String) async -> Result<Void, DomainOperationError> {
        guard let token = tokenProvider() else { return .failure(.noToken) }
        switch await resolveZone(domain: domain, token: token) {
        case .failure(let error):
            return .failure(error)
        case .success(let zoneID):
            do {
                try await writer.deleteDNSRecord(zoneID: zoneID, recordID: recordID, apiToken: token)
                return .success(())
            } catch let error as CloudflareError {
                return .failure(.cloudflare(error))
            } catch {
                return .failure(.cloudflare(.malformedResponse))
            }
        }
    }
}
