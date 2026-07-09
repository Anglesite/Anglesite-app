import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CloudflareWebAnalyticsSite: Sendable, Equatable {
    public let host: String
    public let siteTag: String

    public init(host: String, siteTag: String) {
        self.host = host
        self.siteTag = siteTag
    }
}

public enum CloudflareWebAnalyticsError: Error, LocalizedError, Sendable, Equatable {
    case missingToken
    case noAccount
    case noMatchingSite(String)
    case invalidResponse
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Cloudflare API token is not configured."
        case .noAccount:
            return "No Cloudflare account was available for this token."
        case .noMatchingSite(let host):
            return "Cloudflare Web Analytics is not enabled for \(host)."
        case .invalidResponse:
            return "Cloudflare returned an unexpected Web Analytics response."
        case .api(let message):
            return message
        }
    }
}

public protocol CloudflareWebAnalyticsProviding: Sendable {
    func siteTag(for host: String, apiToken: String) async throws -> String
}

public struct CloudflareWebAnalyticsClient: CloudflareWebAnalyticsProviding {
    private let baseURL: URL
    private let urlSession: URLSession

    public init(baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
                urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func siteTag(for host: String, apiToken: String) async throws -> String {
        let accounts = try await accounts(apiToken: apiToken)
        guard let accountID = accounts.first?.id else { throw CloudflareWebAnalyticsError.noAccount }
        let sites = try await webAnalyticsSites(accountID: accountID, apiToken: apiToken)
        guard let site = Self.matchingSite(for: host, in: sites) else {
            throw CloudflareWebAnalyticsError.noMatchingSite(host)
        }
        return site.siteTag
    }

    public static func matchingSite(for host: String, in sites: [CloudflareWebAnalyticsSite]) -> CloudflareWebAnalyticsSite? {
        let normalized = normalizeHost(host)
        return sites.first { normalizeHost($0.host) == normalized }
    }

    private func accounts(apiToken: String) async throws -> [Account] {
        let envelope: Envelope<[Account]> = try await get("accounts", apiToken: apiToken)
        return envelope.result
    }

    private func webAnalyticsSites(accountID: String, apiToken: String) async throws -> [CloudflareWebAnalyticsSite] {
        let envelope: Envelope<[SiteInfo]> = try await get("accounts/\(accountID)/rum/site_info/list", apiToken: apiToken)
        return envelope.result.map { CloudflareWebAnalyticsSite(host: $0.host, siteTag: $0.siteTag) }
    }

    private func get<T: Decodable>(_ path: String, apiToken: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).errors.first?.message)
                ?? "Cloudflare API request failed with HTTP \(http.statusCode)."
            throw CloudflareWebAnalyticsError.api(message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudflareWebAnalyticsError.invalidResponse
        }
    }

    private static func normalizeHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/.*$"#, with: "", options: .regularExpression)
    }

    private struct Envelope<Result: Decodable>: Decodable {
        let result: Result
    }

    private struct ErrorEnvelope: Decodable {
        let errors: [APIError]
    }

    private struct APIError: Decodable {
        let message: String
    }

    private struct Account: Decodable {
        let id: String
    }

    private struct SiteInfo: Decodable {
        let host: String
        let siteTag: String

        enum CodingKeys: String, CodingKey {
            case host
            case siteTag = "site_tag"
        }
    }
}
