import Foundation

/// Observes which permission groups a stored Cloudflare token actually has, by issuing one cheap
/// authenticated GET per group. 401/403 means the group is missing; any other response (including
/// 404s like "Email Routing not enabled") proves the permission. A thrown transport error counts as
/// missing — probes are advisory and callers may re-probe.
///
/// This exists so wizards can gate on `TokenCapabilities` up front and route the user through token
/// re-onboarding (`AnglesiteTokenTemplate`) instead of failing halfway through an API orchestration.
///
/// This type intentionally ships without production callers in Slice 0; the first consumers (wizard
/// gating + persisted capabilities) land with Slice 1 per
/// `docs/superpowers/specs/2026-07-04-cloudflare-free-services-integration-design.md` §4.
public struct CloudflareCapabilityProber: Sendable {
    private let baseURL: URL
    private let transport: CloudflareTransport

    public init(
        baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func probe(token: String, zoneID: String?) async -> TokenCapabilities {
        var caps = TokenCapabilities()

        var probes: [(TokenCapability, String)] = []
        if let accountID = await firstAccountID(token: token) {
            probes += [
                (.workers, "accounts/\(accountID)/workers/scripts"),
                (.turnstile, "accounts/\(accountID)/challenges/widgets"),
                (.registrar, "accounts/\(accountID)/registrar/domains"),
            ]
        }
        if let zoneID {
            probes += [
                (.zoneSettings, "zones/\(zoneID)/settings/ssl"),
                (.dns, "zones/\(zoneID)/dns_records?per_page=1"),
                (.wafRules, "zones/\(zoneID)/rulesets/phases/http_request_firewall_custom/entrypoint"),
                (.responseCompression, "zones/\(zoneID)/rulesets/phases/http_response_compression/entrypoint"),
                (.emailRouting, "zones/\(zoneID)/email/routing"),
                (.zaraz, "zones/\(zoneID)/settings/zaraz/config"),
                (.pageShield, "zones/\(zoneID)/page_shield"),
            ]
        }
        await withTaskGroup(of: (TokenCapability, Bool).self) { group in
            for (cap, path) in probes {
                group.addTask { (cap, await self.allowed(path, token: token)) }
            }
            for await (cap, isAllowed) in group where isAllowed {
                caps.insert(cap)
            }
        }
        return caps
    }

    /// First account id visible to the token, or nil (account-scoped probes are then skipped).
    private func firstAccountID(token: String) async -> String? {
        struct Envelope: Decodable { let result: [Account]?; struct Account: Decodable { let id: String } }
        guard let (data, http) = try? await get("accounts?per_page=1", token: token),
              (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return envelope.result?.first?.id
    }

    private func allowed(_ path: String, token: String) async -> Bool {
        guard let (_, http) = try? await get(path, token: token) else { return false }
        return http.statusCode != 401 && http.statusCode != 403
    }

    private func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else {
            throw CloudflareError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await transport(request)
    }
}
