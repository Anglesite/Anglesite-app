import Foundation
import CryptoKit

/// A per-session bearer secret minted by the app and validated in-container (auth-proxy + MCP
/// sidecar). Opaque; symmetric compare. The value is a secret — never log it (see `KeychainStore`).
public struct SessionToken: Sendable, Equatable, CustomStringConvertible {
    public let value: String

    public init(value: String) { self.value = value }

    /// 32 cryptographically-random bytes, hex-encoded (64 chars).
    public static func mint() -> SessionToken {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
        return SessionToken(value: bytes.map { String(format: "%02x", $0) }.joined())
    }

    /// Redacted — keeps the secret out of logs and crash dumps.
    public var description: String { "SessionToken(redacted)" }
}
