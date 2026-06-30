import Foundation

/// Generates the wrangler.toml and entry-point configuration for a per-site Cloudflare Worker
/// that composes `@dwk/*` social endpoints behind the site's static assets.
///
/// Today's deploy is static-only (`wrangler deploy` with `[assets]`). The social layer (V-2+)
/// adds a Worker script that mounts `@dwk/indieauth`, `@dwk/webmention`, etc. under path
/// prefixes. This type generates the configuration; actual CF resource provisioning (D1/R2
/// creation) is a V-2.1 task (#353).
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
    }

    private static let validNamePattern = #/^[A-Za-z0-9_-]+$/#

    /// Generates a wrangler.toml for a site with the given features enabled.
    ///
    /// - Parameters:
    ///   - siteName: The Worker name (used as the Cloudflare Workers project name).
    ///     Must match `[A-Za-z0-9_-]+`.
    ///   - features: Which `@dwk/*` social endpoints to compose. Empty = static-only deploy.
    /// - Returns: A complete wrangler.toml string.
    /// - Throws: ``ConfigError/invalidSiteName(_:)`` if `siteName` contains
    ///   characters outside `[A-Za-z0-9_-]`.
    public static func generateWranglerToml(
        siteName: String,
        features: [Feature]
    ) throws -> String {
        guard siteName.wholeMatch(of: validNamePattern) != nil else {
            throw ConfigError.invalidSiteName(siteName)
        }
        var lines: [String] = []
        lines.append("name = \"\(siteName)\"")
        lines.append("compatibility_date = \"2025-01-01\"")

        let hasSocialFeatures = !features.isEmpty
        if hasSocialFeatures {
            lines.append("main = \"worker/worker.ts\"")
        }
        lines.append("")
        lines.append("[assets]")
        lines.append("directory = \"dist\"")

        if features.contains(where: { $0.needsD1 }) {
            lines.append("")
            lines.append("[[d1_databases]]")
            lines.append("binding = \"DB\"")
            lines.append("database_name = \"\(siteName)-social\"")
            lines.append("database_id = \"\"  # filled by provisioning")
        }

        if features.contains(where: { $0.needsR2 }) {
            lines.append("")
            lines.append("[[r2_buckets]]")
            lines.append("binding = \"MEDIA\"")
            lines.append("bucket_name = \"\(siteName)-media\"")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }
}
