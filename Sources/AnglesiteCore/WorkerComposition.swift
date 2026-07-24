import Foundation

/// Generates the wrangler.toml and entry-point configuration for a per-site Cloudflare Worker
/// that composes `@dwk/*` social endpoints behind the site's static assets.
///
/// Today's deploy is static-only (`wrangler deploy` with `[assets]`). The social layer (V-2+)
/// adds a Worker script that mounts `@dwk/indieauth`, `@dwk/webmention`, etc. under path
/// prefixes. This type generates the configuration; `SocialWorkerProvisionCommand` fills the
/// Cloudflare resource identifiers once provisioning has created the backing stores.
public enum WorkerComposition {

    public enum ConfigError: Error, Sendable {
        case invalidSiteName(String)
        /// A route claim reached TOML generation without passing `WorkerRouteClaims` validation
        /// (callers derive claims via `WorkerRouteClaims.activeClaims`, which validates; this is
        /// the defense-in-depth backstop so an unvalidated path can never be interpolated into
        /// the generated file).
        case invalidRouteClaim(path: String, reason: String)
    }

    /// `@dwk/indieauth`'s catalog id — a magic string composition keys off directly (its binding
    /// name, `AUTH_DB`, is part of its public contract, unlike every other `@dwk/*` package which
    /// only needs generic `resources` flags), shared so a typo in one comparison site can't
    /// silently diverge from another.
    public static let indieauthWorkerID = "indieauth"

    /// `@dwk/webmention`'s catalog id — like `indieauthWorkerID`, composition keys off this
    /// directly for the receiver's three bespoke bindings (`WEBMENTION_INBOX`, the Queue,
    /// `SITE_URL`), since those binding names are part of `@dwk/webmention`'s public composition
    /// contract, not something a generic `resources` flag can express without a paired schema
    /// change in the external `davidwkeith/workers` catalog repo.
    public static let webmentionWorkerID = "webmention"

    /// `@dwk/micropub`'s catalog id — like `webmentionWorkerID`, composition keys off this
    /// directly for the create/update/delete endpoint's bespoke `MICROPUB_DB` binding, since that
    /// binding name is part of `@dwk/micropub`'s public composition contract, not something a
    /// generic `resources` flag can express. `MEDIA` (R2) is covered by the existing generic
    /// `needsR2` branch below — Micropub's catalog entry declares an `r2` resource, so it falls
    /// out for free once `WorkerDescriptor.Resources` decodes that entry correctly.
    public static let micropubWorkerID = "micropub"

    /// `@dwk/activitypub`'s catalog id — like `webmentionWorkerID`/`micropubWorkerID`, composition
    /// keys off this directly for the actor's bespoke `ACTOR` Durable Object binding, since the
    /// binding name and class name (`ActivityPubObject`) are part of `@dwk/activitypub`'s public
    /// composition contract (its README documents the exact `durable_objects`/`migrations` shape),
    /// not something the generic `resources` flags (`needsD1`/`needsKV`/`needsR2`) can express.
    public static let activitypubWorkerID = "activitypub"

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
        /// The Cloudflare Queue name backing `@dwk/webmention`'s async verify step. Like
        /// `r2BucketName`, this is a deterministic name (`\(siteName)-webmention`), not an id —
        /// wrangler.toml's `[[queues.*]]` blocks reference queues by name.
        public var queueName: String?

        public init(
            d1DatabaseID: String? = nil, kvNamespaceID: String? = nil, r2BucketName: String? = nil,
            queueName: String? = nil
        ) {
            self.d1DatabaseID = d1DatabaseID
            self.kvNamespaceID = kvNamespaceID
            self.r2BucketName = r2BucketName
            self.queueName = queueName
        }
    }

    /// Generates a wrangler.toml for a site with the given workers enabled.
    ///
    /// - Parameters:
    ///   - siteName: The Worker name (used as the Cloudflare Workers project name).
    ///     Must match `[A-Za-z0-9_-]+`.
    ///   - workers: The effective active `@dwk/workers` catalog descriptors. Empty = static-only
    ///     deploy.
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
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim] = [],
        resources: ProvisionedResources = .init(),
        inboxCaptureEnabled: Bool = false,
        inboxKVNamespaceID: String? = nil,
        siteURL: String? = nil,
        /// The site's display name (`SiteSettings.displayName`, already falling back to the site
        /// name by the time a caller passes it in — this function stays pure and does no
        /// fallback of its own), threaded into the ActivityPub actor's `AP_DISPLAY_NAME` var.
        /// `nil` when unknown; the composed Worker's actor document then falls back to a fixed
        /// generic name (`worker.ts`'s concern, not this function's).
        displayName: String? = nil
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
        // @dwk/indieauth's binding name is part of its public composition contract (see the
        // AUTH_DB block below) — the one place composition keys off a specific catalog id rather
        // than generic resource flags.
        let hasIndieauth = workers.contains(where: { $0.id == indieauthWorkerID })
        let hasWebmentionReceive = workers.contains(where: { $0.id == webmentionWorkerID })
        let hasMicropub = workers.contains(where: { $0.id == micropubWorkerID })
        let hasActivityPub = workers.contains(where: { $0.id == activitypubWorkerID })

        var lines: [String] = []
        lines.append("name = \"\(siteName)\"")
        lines.append("compatibility_date = \"2026-07-15\"")
        lines.append("compatibility_flags = [\"nodejs_compat\"]")

        let hasSocialFeatures = !workers.isEmpty
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

        if workers.contains(where: { $0.resources.needsD1 }) {
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

        // Keep the generic DB binding above for the other @dwk packages, while binding the same
        // per-site D1 database under AUTH_DB for authorization codes and issued-token state.
        if hasIndieauth {
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

        // Same shared per-site D1 database as DB/AUTH_DB, bound a third time under
        // WEBMENTION_INBOX — @dwk/webmention's createD1Inbox creates its own `webmentions`
        // table on first use, so no separate database or migration is needed here.
        if hasWebmentionReceive {
            lines.append("")
            lines.append("[[d1_databases]]")
            lines.append("binding = \"WEBMENTION_INBOX\"")
            lines.append("database_name = \"\(siteName)-social\"")
            if let id = resources.d1DatabaseID, !id.isEmpty {
                lines.append("database_id = \"\(id)\"")
            } else {
                lines.append("database_id = \"\"  # filled by provisioning")
            }
        }

        // Same shared per-site D1 database as DB/AUTH_DB/WEBMENTION_INBOX, bound a fourth time
        // under MICROPUB_DB — @dwk/micropub creates its own tables on first use, so no separate
        // database or migration is needed here (matches the WEBMENTION_INBOX comment above).
        if hasMicropub {
            lines.append("")
            lines.append("[[d1_databases]]")
            lines.append("binding = \"MICROPUB_DB\"")
            lines.append("database_name = \"\(siteName)-social\"")
            if let id = resources.d1DatabaseID, !id.isEmpty {
                lines.append("database_id = \"\(id)\"")
            } else {
                lines.append("database_id = \"\"  # filled by provisioning")
            }
        }

        // Cloudflare Queue backing @dwk/webmention's async verify step. Queues are referenced by
        // name (not id), so — like r2BucketName — this falls back to a deterministic
        // `\(siteName)-webmention` placeholder before provisioning assigns the real one.
        if hasWebmentionReceive {
            lines.append("")
            let queueName = resources.queueName ?? "\(siteName)-webmention"
            lines.append("[[queues.producers]]")
            lines.append("queue = \"\(queueName)\"")
            lines.append("binding = \"WEBMENTION_QUEUE\"")
            lines.append("")
            lines.append("[[queues.consumers]]")
            lines.append("queue = \"\(queueName)\"")
            lines.append("max_batch_size = 10")
            lines.append("max_batch_timeout = 30")
            lines.append("max_retries = 3")
        }

        if workers.contains(where: { $0.resources.needsKV }) {
            lines.append("")
            lines.append("[[kv_namespaces]]")
            lines.append("binding = \"SOCIAL_KV\"")
            if let id = resources.kvNamespaceID, !id.isEmpty {
                lines.append("id = \"\(id)\"")
            } else {
                lines.append("id = \"\"  # filled by provisioning")
            }
        }

        if workers.contains(where: { $0.resources.needsR2 }) {
            lines.append("")
            lines.append("[[r2_buckets]]")
            lines.append("binding = \"MEDIA\"")
            lines.append("bucket_name = \"\(resources.r2BucketName ?? "\(siteName)-media")\"")
        }

        if hasActivityPub {
            lines.append("")
            lines.append("[[durable_objects.bindings]]")
            lines.append("name = \"ACTOR\"")
            lines.append("class_name = \"ActivityPubObject\"")
            lines.append("")
            lines.append("[[migrations]]")
            lines.append("tag = \"v1\"")
            lines.append("new_sqlite_classes = [\"ActivityPubObject\"]")
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

        var varsLines: [String] = []
        if hasWebmentionReceive, let siteURL, !siteURL.isEmpty, isSafeTomlStringValue(siteURL) {
            varsLines.append("SITE_URL = \"\(siteURL)\"")
        }
        if hasActivityPub, let displayName, !displayName.isEmpty, isSafeTomlStringValue(displayName) {
            varsLines.append("AP_DISPLAY_NAME = \"\(displayName)\"")
        }
        if !varsLines.isEmpty {
            lines.append("")
            lines.append("[vars]")
            lines.append(contentsOf: varsLines)
        }

        if hasIndieauth {
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

    /// Whether `value` is safe to interpolate as-is into a TOML basic string (`"..."`) — no
    /// double quote, backslash, or control character that could break out of the string literal
    /// or corrupt the generated file. `siteURL` is sourced from `.site-config`, which lives in
    /// the site's git-tracked `Source/` — externally clonable/editable content (CLAUDE.md's "Git
    /// is the source of truth"), so it must be treated the same as any other untrusted input
    /// before being interpolated into generated infrastructure config.
    static func isSafeTomlStringValue(_ value: String) -> Bool {
        !value.contains("\"") && !value.contains("\\")
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}
