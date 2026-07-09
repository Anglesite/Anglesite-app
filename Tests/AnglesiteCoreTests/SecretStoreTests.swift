import Foundation
import Testing
@testable import AnglesiteCore

/// Portable contract tests for the SecretStore seam — run on every platform (unlike
/// `KeychainStoreTests`, which exercises the Darwin implementation against the real
/// keychain). The in-memory store below doubles as a reference for the semantics every
/// platform implementation must uphold.
struct SecretStoreTests {
    /// Minimal conforming store used to pin the protocol-extension convenience methods.
    private final class InMemorySecretStore: SecretStore, @unchecked Sendable {
        private var entries: [String: String] = [:]
        private let lock = NSLock()

        func read(account: String) throws -> String? {
            lock.withLock { entries[account] }
        }

        func write(_ value: String, account: String) throws {
            lock.withLock {
                if value.isEmpty {
                    entries[account] = nil
                } else {
                    entries[account] = value
                }
            }
        }

        func delete(account: String) throws {
            lock.withLock { entries[account] = nil }
        }
    }

    @Test("Cloudflare convenience methods address the shared SecretAccounts slot")
    func cloudflareConvenienceUsesSharedAccount() throws {
        let store = InMemorySecretStore()
        try store.writeCloudflareToken("tok-123")
        #expect(try store.read(account: SecretAccounts.cloudflareToken) == "tok-123")
        #expect(try store.readCloudflareToken() == "tok-123")
        try store.clearCloudflareToken()
        #expect(try store.readCloudflareToken() == nil)
    }

    @Test("UnavailableSecretStore reads nothing, deletes as no-op, and refuses writes")
    func unavailableStoreBehavior() throws {
        let store = UnavailableSecretStore()
        #expect(try store.read(account: "anything") == nil)
        try store.delete(account: "anything")  // must not throw
        #expect(throws: UnavailableSecretStore.WriteUnsupported.self) {
            try store.write("secret", account: "anything")
        }
    }

    @Test("PlatformSecretStore.make returns the platform default")
    func platformDefaultResolves() {
        let store = PlatformSecretStore.make()
        #if canImport(Security)
        #expect(store is KeychainStore)
        #else
        #expect(store is UnavailableSecretStore)
        #endif
    }
}
