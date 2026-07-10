import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cloudflare Workers KV client for the #587 runtime-inbox-capture staging store. The per-site
/// Worker (`Resources/Template/worker/worker.ts`) stages visitor submissions under `inbox:<id>`
/// keys in the `INBOX_KV` namespace; this is the app-side counterpart that lists, reads, and
/// clears those staged entries once they've been committed into the site's git working copy
/// (`InboxSubmissionSync`). Follows the same injectable-transport DI pattern as
/// `HTTPCloudflareClient`/`CloudflareCapabilityProber` — no Keychain coupling, token passed in
/// at init.
public struct InboxKVClient: Sendable {
    /// A visitor submission as staged by the Worker (`worker.ts`'s `handleInbox`) — field names
    /// and shape must match exactly, since the Worker is the writer and this is the reader.
    public struct Submission: Sendable, Equatable, Decodable {
        public let id: String
        public let subject: String
        public let from: String
        public let message: String
        public let receivedAt: String

        public init(id: String, subject: String, from: String, message: String, receivedAt: String) {
            self.id = id
            self.subject = subject
            self.from = from
            self.message = message
            self.receivedAt = receivedAt
        }
    }

    private struct KeyListEnvelope: Decodable {
        struct Key: Decodable { let name: String }
        let success: Bool
        let result: [Key]?
    }

    private static let keyPrefix = "inbox:"

    private let baseURL: String
    private let accountID: String
    private let namespaceID: String
    private let apiToken: String
    private let transport: CloudflareTransport

    public init(
        accountID: String,
        namespaceID: String,
        apiToken: String,
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) {
        self.accountID = accountID
        self.namespaceID = namespaceID
        self.apiToken = apiToken
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Lists every staged submission (`inbox:*` keys), fetching and decoding each value.
    /// Malformed entries (a key whose value fails to decode as `Submission`) are skipped rather
    /// than failing the whole pull — one bad/partial write shouldn't block every other
    /// submission.
    public func listStagedSubmissions() async throws -> [Submission] {
        let keysURLString = "\(baseURL)/accounts/\(accountID)/storage/kv/namespaces/\(namespaceID)/keys"
            + "?prefix=\(Self.keyPrefix)"
        guard let url = URL(string: keysURLString) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        guard let envelope = try? JSONDecoder().decode(KeyListEnvelope.self, from: data), envelope.success else {
            throw CloudflareError.malformedResponse
        }

        var submissions: [Submission] = []
        for key in envelope.result ?? [] {
            guard let submission = try? await fetchSubmission(key: key.name) else { continue }
            submissions.append(submission)
        }
        return submissions
    }

    /// Deletes a staged submission by id — called only after it has been successfully committed
    /// into the site's git working copy, so a mid-pull failure leaves the entry staged for retry
    /// rather than losing it.
    public func deleteSubmission(id: String) async throws {
        let valueURLString = "\(baseURL)/accounts/\(accountID)/storage/kv/namespaces/\(namespaceID)/values/"
            + "\(Self.keyPrefix)\(id)"
        guard let url = URL(string: valueURLString) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        let (_, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
    }

    private func fetchSubmission(key: String) async throws -> Submission {
        let valueURLString = "\(baseURL)/accounts/\(accountID)/storage/kv/namespaces/\(namespaceID)/values/\(key)"
        guard let url = URL(string: valueURLString) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await transport(request)
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        return try JSONDecoder().decode(Submission.self, from: data)
    }
}
