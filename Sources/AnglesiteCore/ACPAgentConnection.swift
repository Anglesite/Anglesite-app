import Foundation

/// One user-registered connection to an ACP (Agent Client Protocol) agent — Zed's JSON-RPC
/// protocol for editor<->agent communication. Non-secret fields only; a `.remote` connection's
/// bearer token lives in `SecretStore` under `SecretAccounts.acpAgentToken(id:)`, keyed by `id`.
public struct ACPAgentConnection: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var transport: Transport

    public enum Transport: Codable, Sendable, Equatable {
        /// Launched inside the open site's container, alongside the dev server and MCP sidecar.
        case stdio(command: String, arguments: [String])
        /// Reached over the network; the bearer token (if any) is stored separately in Keychain.
        case remote(url: URL)
    }

    public init(id: UUID, name: String, transport: Transport) {
        self.id = id
        self.name = name
        self.transport = transport
    }
}
