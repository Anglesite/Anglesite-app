import Foundation

// Same toolchain/runtime gate as `ContentAssistant.swift` — `Generable` (used only by the
// `generateStructured` conformance below) comes from FoundationModels, which is absent from
// GitHub's macos-15 CI runner at *load* time even when the SDK has the symbol at compile time.
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif

/// `ConversationalAssistant` backed by an ACP agent connection (`ACPAgentConnection`). Constructed
/// synchronously (matching `FoundationModelAssistant`'s init) — the actual transport/handshake
/// happens lazily on first `converse`/`generate`, so building this assistant never blocks on a
/// container being up or a network round trip.
///
/// Proof-of-concept scope (ACP agent settings design spec §4.4): implements enough (`session/new`
/// + single-turn prompt/response) to make "switch which model answers chat" real. No multi-turn
/// tool-permission UI yet — `ACPClient` auto-declines any `session/request_permission`.
public actor ACPAssistant: ConversationalAssistant {
    public typealias ContainerControlProvider = @Sendable () async -> (siteID: String, control: any LocalContainerControl)?

    public enum ACPAssistantError: Error, Sendable, Equatable {
        /// A `.stdio` connection is active but no container is currently running for this site
        /// (e.g. the preview hasn't finished starting yet).
        case containerUnavailable
    }

    private let connection: ACPAgentConnection
    private let siteID: String
    private let sourceDirectory: URL
    private let makeTransport: @Sendable () async throws -> any ACPTransport

    private var client: ACPClient?
    private var sessionID: String?

    public init(
        connection: ACPAgentConnection,
        siteID: String,
        sourceDirectory: URL,
        containerControlProvider: @escaping ContainerControlProvider = { nil },
        secretStore: any SecretStore = PlatformSecretStore.make(),
        transportFactory: (@Sendable () async throws -> any ACPTransport)? = nil
    ) {
        self.connection = connection
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        if let transportFactory {
            self.makeTransport = transportFactory
        } else {
            self.makeTransport = {
                switch connection.transport {
                case .stdio(let command, let arguments):
                    guard let snapshot = await containerControlProvider() else {
                        throw ACPAssistantError.containerUnavailable
                    }
                    return ACPContainerExecTransport(
                        control: snapshot.control, siteID: snapshot.siteID,
                        command: command, arguments: arguments
                    )
                case .remote(let url):
                    let token = try? secretStore.readACPAgentToken(id: connection.id)
                    return ACPHTTPTransport(endpoint: url, bearerToken: token.map { SessionToken(value: $0) })
                }
            }
        }
    }

    public nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true, supportsStructuredOutput: false, supportsVision: false,
            supportsTools: true, maxContextTokens: nil, providerName: connection.name
        )
    }

    public func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        let events = try await converse(prompt: prompt, context: context)
        return AsyncThrowingStream { continuation in
            Task {
                for await event in events {
                    switch event {
                    case .textDelta(let text): continuation.yield(text)
                    case .failed(let message): continuation.finish(throwing: AssistantError.streamFailed(message)); return
                    case .turnComplete, .backendExited: continuation.finish(); return
                    default: break
                    }
                }
                continuation.finish()
            }
        }
    }

    #if compiler(>=6.4) && canImport(FoundationModels)
    public func generateStructured<T: Generable & Sendable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        throw AssistantError.unsupported("ACP agents do not support FoundationModels guided generation")
    }
    #endif

    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        let client = try await connectedClient()
        let sessionID = try await ensureSession(client: client)
        return try await client.sendPrompt(sessionID: sessionID, text: prompt)
    }

    /// `session/new`'s `cwd` means different filesystems depending on transport: a `.stdio` agent
    /// runs inside the site's container, where the repo is always cloned to the fixed guest path
    /// `/workspace/site` (matches `DeployExecutor`'s convention); a `.remote` agent runs wherever
    /// its own host is, where the only filesystem path that means anything to it is the one on
    /// THIS Mac — `sourceDirectory`.
    private var effectiveWorkingDirectory: String {
        switch connection.transport {
        case .stdio: return "/workspace/site"
        case .remote: return sourceDirectory.path
        }
    }

    public func cancel() async {
        guard let client, let sessionID else { return }
        await client.cancelSession(sessionID: sessionID)
    }

    public func resetSession() async {
        sessionID = nil
    }

    private func connectedClient() async throws -> ACPClient {
        if let client { return client }
        let transport = try await makeTransport()
        let newClient = ACPClient(transport: transport)
        try await newClient.initialize()
        client = newClient
        return newClient
    }

    private func ensureSession(client: ACPClient) async throws -> String {
        if let sessionID { return sessionID }
        let newSessionID = try await client.newSession(cwd: effectiveWorkingDirectory)
        sessionID = newSessionID
        return newSessionID
    }
}
