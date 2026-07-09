import Foundation

/// Portable seam for storing small user secrets (API tokens) — seam 1 of the cross-platform
/// port design (docs/superpowers/specs/2026-07-08-cross-platform-swift-port-design.md §5).
///
/// Implementations: `KeychainStore` (Darwin, SecItem generic passwords); a libsecret/Secret
/// Service store arrives with the Linux MVP; Windows gets Credential Manager. Platforms
/// without a native implementation yet use `UnavailableSecretStore`, which reads as "nothing
/// stored" and refuses writes — features degrade capability-flagged, never by silently
/// dropping a secret.
///
/// Semantics all implementations must uphold (mirrored from `KeychainStore`, the reference
/// implementation, and pinned by its test suite):
/// - `read` returns `nil` (not an error) when no entry exists.
/// - `write("")` deletes the entry, so an empty write round-trips as `read → nil`.
/// - `delete` of a missing entry is a no-op, not an error.
/// - Values are secrets: implementations and callers must never log them.
public protocol SecretStore: Sendable {
    /// Returns the stored secret for `account`, or `nil` if no entry exists.
    func read(account: String) throws -> String?
    /// Writes `value` for `account`, replacing any existing entry. An empty `value` deletes.
    func write(_ value: String, account: String) throws
    /// Removes the stored entry for `account`. No-op if no entry exists.
    func delete(account: String) throws
}

/// Well-known account keys, shared across platform stores so the Settings UI, deploy path,
/// and onboarding all address the same slot regardless of backend.
public enum SecretAccounts {
    /// The Cloudflare API token used by `wrangler deploy`.
    public static let cloudflareToken = "cloudflare-api-token"
}

public extension SecretStore {
    /// Read the Cloudflare API token under the shared account key.
    func readCloudflareToken() throws -> String? {
        try read(account: SecretAccounts.cloudflareToken)
    }

    /// Store the Cloudflare API token under the shared account key. Empty string clears.
    func writeCloudflareToken(_ token: String) throws {
        try write(token, account: SecretAccounts.cloudflareToken)
    }

    /// Clear the Cloudflare API token slot.
    func clearCloudflareToken() throws {
        try delete(account: SecretAccounts.cloudflareToken)
    }
}

/// Placeholder store for platforms without a native secret-store implementation yet
/// (Linux until the libsecret store lands). Reads report "nothing stored" so token
/// resolution falls through to environment variables; writes fail loudly rather than
/// pretending a secret was persisted.
public struct UnavailableSecretStore: SecretStore {
    public struct WriteUnsupported: Error {}

    public init() {}

    public func read(account: String) throws -> String? { nil }

    public func write(_ value: String, account: String) throws {
        // Uphold the protocol contract: an empty write means delete, and deleting from a
        // store that holds nothing is a successful no-op. Only persisting is unsupported.
        if value.isEmpty { return }
        throw WriteUnsupported()
    }

    public func delete(account: String) throws {}
}

/// Composition-root factory for the platform's default secret store. Call sites in the
/// portable core depend on `any SecretStore` and use this only as their production default;
/// tests and the app shell inject concrete stores directly.
public enum PlatformSecretStore {
    public static func make() -> any SecretStore {
        #if canImport(Security)
        KeychainStore()
        #else
        UnavailableSecretStore()
        #endif
    }
}
