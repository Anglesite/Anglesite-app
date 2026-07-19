import Foundation

/// Generates the wrangler.toml and entry-point configuration for a per-site Cloudflare Worker
/// that composes `@dwk/*` social endpoints behind the site's static assets.
///
/// Today's deploy is static-only (`wrangler deploy` with `[assets]`). The social layer (V-2+)
/// adds a Worker script that mounts `@dwk/indieauth`, `@dwk/webmention`, etc. under path
/// prefixes. This type generates the configuration; `SocialWorkerProvisionCommand` fills the
/// Cloudflare resource identifiers once provisioning has created the backing stores.
public enum WorkerComposition {
    /// A social feature that can be composed into the per-site Worker.
    public enum Feature: String, CaseIterable, Sendable {
        case indieauth
        case webmention
        case micropub
        case websub
        case microsub
        case webfinger
        case activitypub

        /// V-2 features: outbound social (webmention send + indieauth).
        public static let v2: [Feature] = [.webmention, .indieauth]
        /// V-3 features: V-2 + inbound social (micropub + websub).
        public static let v3: [Feature] = [.webmention, .indieauth, .micropub, .websub]
        /// V-4 features: V-3 + federation (activitypub + microsub + webfinger).
        public static let v4: [Feature] = Array(Feature.allCases)

        var needsD1: Bool {
            switch self {
            case .webmention, .micropub, .indieauth, .websub, .microsub, .activitypub:
                return true
            case .webfinger:
                return false
            }
        }

        var needsKV: Bool {
            switch self {
            case .webmention, .micropub, .indieauth, .websub, .microsub, .activitypub:
                return true
            case .webfinger:
                return false
            }
        }

        var needsR2: Bool {
            switch self {
            case .micropub:
                return true
            default:
                return false
            }
        }
    }

    public enum ConfigError: Error, Sendable {
        case invalidSiteName(String)
        /// A route claim reached TOML generation without passing `WorkerRouteClaims` validation
        /// (callers derive claims via `WorkerRouteClaims.activeClaims`, which validates; this is
        /// the defense-in-depth backstop so an unvalidated path can never be interpolated into
        /// the generated file).
        case invalidRouteClaim(path: String, reason: String)
    }

    /// The bespoke app-side inbox-capture route (#587) — not a `@dwk/workers` catalog worker, so
    /// its claim lives here rather than in `catalog.json`. Appended automatically when
    /// `generateWranglerToml` is called with `inboxCaptureEnabled`.
    public static let inboxCaptureRouteClaim = WorkerRouteClaim(
        path: "/inbox",
        match: .exact,
        methods: ["POST"],
        handler: "inbox-capture"
    )

    private static let validNameCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )

    public struct ProvisionedResources: Sendable, Equatable, Codable {
        public var d1DatabaseID: String?
        public var kvNamespaceID: String?
        public var r2BucketName: String?

        public init(d1DatabaseID: String? = nil, kvNamespaceID: String? = nil, r2BucketName: String? = nil) {
            self.d1DatabaseID = d1DatabaseID
            self.kvNamespaceID = kvNamespaceID
            self.r2BucketName = r2BucketName
        }
    }

    /// Generates a wrangler.toml for a site with the given features enabled.
    ///
    /// - Parameters:
    ///   - siteName: The Worker name (used as the Cloudflare Workers project name).
    ///     Must match `[A-Za-z0-9_-]+`.
    ///   - features: Which `@dwk/*` social endpoints to compose. Empty = static-only deploy.
    ///   - routeClaims: The effective active dynamic-route claims (#746), already validated by
    ///     `WorkerRouteClaims.activeClaims`. Emitted as selective `[assets].run_worker_first`
    ///     patterns so *only* claimed routes bypass asset-first serving — a static asset can no
    ///     longer shadow an active dynamic route, while every unclaimed path keeps Cloudflare's
    ///     asset-first fallback. Omitted entirely when there are no active dynamic routes.
    /// - Returns: A complete wrangler.toml string.
    /// - Throws: ``ConfigError/invalidSiteName(_:)`` if `siteName` contains
    ///   characters outside `[A-Za-z0-9_-]`, or ``ConfigError/invalidRouteClaim(path:reason:)``
    ///   for a claim that never passed `WorkerRouteClaims` validation.
    public static func generateWranglerToml(
        siteName: String,
        features: [Feature],
        routeClaims: [WorkerRouteClaim] = [],
        resources: ProvisionedResources = .init(),
        inboxCaptureEnabled: Bool = false,
        inboxKVNamespaceID: String? = nil
    ) throws -> String {
        guard isValidSiteName(siteName) else {
            throw ConfigError.invalidSiteName(siteName)
        }
        var effectiveClaims = routeClaims
        if inboxCaptureEnabled {
            effectiveClaims.append(inboxCaptureRouteClaim)
        }
        // Full single-claim validation (not just path syntax), so a future caller that skips
        // `WorkerRouteClaims.activeClaims` still can't emit an invalid claim into TOML. Cross-
        // claim overlap detection remains `activeClaims`'s job — it needs owner attribution
        // this signature doesn't carry.
        for claim in effectiveClaims {
            do {
                try WorkerRouteClaims.validate(claim, owner: "composition")
            } catch {
                throw ConfigError.invalidRouteClaim(path: claim.path, reason: "\(error)")
            }
        }
        var lines: [String] = []
        lines.append("name = \"\(siteName)\"")
        lines.append("compatibility_date = \"2026-07-15\"")
        lines.append("compatibility_flags = [\"nodejs_compat\"]")

        let hasSocialFeatures = !features.isEmpty
        if hasSocialFeatures || inboxCaptureEnabled {
            lines.append("main = \"worker/worker.ts\"")
        }
        lines.append("")
        lines.append("[assets]")
        lines.append("directory = \"dist\"")
        if hasSocialFeatures || inboxCaptureEnabled {
            lines.append("binding = \"ASSETS\"")
            let patterns = WorkerRouteClaims.runWorkerFirstPatterns(effectiveClaims)
            if !patterns.isEmpty {
                let list = patterns.map { "\"\($0)\"" }.joined(separator: ", ")
                lines.append("run_worker_first = [\(list)]")
            }
        }

        if features.contains(where: { $0.needsD1 }) {
            lines.append("")
            lines.append("[[d1_databases]]")
            lines.append("binding = \"DB\"")
            lines.append("database_name = \"\(siteName)-social\"")
            if let id = resources.d1DatabaseID, !id.isEmpty {
                lines.append("database_id = \"\(id)\"")
            } else {
                lines.append("database_id = \"\"  # filled by provisioning")
            }
        }

        // @dwk/indieauth's binding name is part of its public composition contract. Keep the
        // generic DB binding above for the other @dwk packages, while binding the same per-site
        // D1 database under AUTH_DB for authorization codes and issued-token state.
        if features.contains(.indieauth) {
            lines.append("")
            lines.append("[[d1_databases]]")
            lines.append("binding = \"AUTH_DB\"")
            lines.append("database_name = \"\(siteName)-social\"")
            lines.append("migrations_dir = \"worker/migrations\"")
            if let id = resources.d1DatabaseID, !id.isEmpty {
                lines.append("database_id = \"\(id)\"")
            } else {
                lines.append("database_id = \"\"  # filled by provisioning")
            }
        }

        if features.contains(where: { $0.needsKV }) {
            lines.append("")
            lines.append("[[kv_namespaces]]")
            lines.append("binding = \"SOCIAL_KV\"")
            if let id = resources.kvNamespaceID, !id.isEmpty {
                lines.append("id = \"\(id)\"")
            } else {
                lines.append("id = \"\"  # filled by provisioning")
            }
        }

        if features.contains(where: { $0.needsR2 }) {
            lines.append("")
            lines.append("[[r2_buckets]]")
            lines.append("binding = \"MEDIA\"")
            lines.append("bucket_name = \"\(resources.r2BucketName ?? "\(siteName)-media")\"")
        }

        if inboxCaptureEnabled {
            lines.append("")
            lines.append("[[kv_namespaces]]")
            lines.append("binding = \"INBOX_KV\"")
            if let id = inboxKVNamespaceID, !id.isEmpty {
                lines.append("id = \"\(id)\"")
            } else {
                lines.append("id = \"\"  # filled by provisioning")
            }
        }

        if features.contains(.indieauth) {
            lines.append("")
            // Wrangler has no schema for declaring required secrets in wrangler.toml — secrets are
            // set with `wrangler secret put <NAME>` and are never read back out of this file. Emit
            // this as a comment (not a `[secrets]` table) so it can't be mistaken for a config key
            // wrangler validates or fail on.
            lines.append("# Secrets required for IndieAuth (set with `wrangler secret put <NAME>`):")
            lines.append("# TOKEN_SIGNING_KEY, INDIEAUTH_OWNER_PASSWORD")
        }

        if hasSocialFeatures || inboxCaptureEnabled {
            lines.append("")
            lines.append("[observability]")
            lines.append("enabled = true")
            lines.append("head_sampling_rate = 1")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func isValidSiteName(_ siteName: String) -> Bool {
        guard !siteName.isEmpty else { return false }
        return siteName.unicodeScalars.allSatisfy { validNameCharacters.contains($0) }
    }
}
