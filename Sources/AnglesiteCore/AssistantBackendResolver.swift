import Foundation

/// Resolves `AppSettings.activeAssistantBackend` into an `ACPAssistant`, or `nil` when the active
/// backend is `"foundationModels"` (the default) or references an agent that no longer exists —
/// `SiteAssistantSessionFactory` falls back to the existing `FoundationModelAssistant` path on
/// `nil`, exactly like `ContentAssistantFactory`'s "not compiled in" `nil` case (ACP agent
/// settings design spec §4.5).
public enum AssistantBackendResolver {
    /// Parses the `"acp:<uuid>"` convention. Returns `nil` for `"foundationModels"` or any
    /// malformed value — callers treat that as "use Foundation Models."
    public static func activeAgentID(from raw: String) -> UUID? {
        guard raw.hasPrefix("acp:") else { return nil }
        return UUID(uuidString: String(raw.dropFirst(4)))
    }

    public static func resolveActiveACPAssistant(
        siteID: String,
        sourceDirectory: URL,
        containerControlProvider: @escaping ACPAssistant.ContainerControlProvider,
        agentStore: ACPAgentStore = ACPAgentStore(),
        appSettings: AppSettings = .shared,
        secretStore: any SecretStore = PlatformSecretStore.make()
    ) -> ACPAssistant? {
        guard let agentID = activeAgentID(from: appSettings.activeAssistantBackend) else { return nil }
        guard let connections = try? agentStore.load(),
              let connection = connections.first(where: { $0.id == agentID }) else { return nil }
        return ACPAssistant(
            connection: connection,
            siteID: siteID,
            sourceDirectory: sourceDirectory,
            containerControlProvider: containerControlProvider,
            secretStore: secretStore
        )
    }
}
