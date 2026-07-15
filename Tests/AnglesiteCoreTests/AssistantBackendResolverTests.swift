import Testing
import Foundation
@testable import AnglesiteCore

final class AssistantBackendResolverTests {
    private let tempDir: URL
    private let persistenceURL: URL
    private let fileManager = FileManager.default
    private let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("assistant-backend-resolver-\(UUID().uuidString)", isDirectory: true)
        persistenceURL = tempDir.appendingPathComponent("acp-agents.json")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "test-anglesite-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("activeAgentID parses a well-formed acp: prefix") func activeAgentIDParsesWellFormedPrefix() {
        let id = UUID()
        #expect(AssistantBackendResolver.activeAgentID(from: "acp:\(id.uuidString)") == id)
    }

    @Test("activeAgentID returns nil for foundationModels") func activeAgentIDReturnsNilForFoundationModels() {
        #expect(AssistantBackendResolver.activeAgentID(from: "foundationModels") == nil)
    }

    @Test("activeAgentID returns nil for a malformed UUID") func activeAgentIDReturnsNilForMalformedUUID() {
        #expect(AssistantBackendResolver.activeAgentID(from: "acp:not-a-uuid") == nil)
    }

    @Test("resolveActiveACPAssistant returns nil when backend is foundationModels") func resolveReturnsNilWhenBackendIsFoundationModels() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "foundationModels"
        let resolved = AssistantBackendResolver.resolveActiveACPAssistant(
            siteID: "site-1", sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            containerControlProvider: { nil },
            agentStore: ACPAgentStore(persistenceURL: persistenceURL), appSettings: settings
        )
        #expect(resolved == nil)
    }

    @Test("resolveActiveACPAssistant returns nil when the referenced agent is missing") func resolveReturnsNilWhenAgentMissing() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "acp:\(UUID().uuidString)"
        let resolved = AssistantBackendResolver.resolveActiveACPAssistant(
            siteID: "site-1", sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            containerControlProvider: { nil },
            agentStore: ACPAgentStore(persistenceURL: persistenceURL), appSettings: settings
        )
        #expect(resolved == nil)
    }

    @Test("resolveActiveACPAssistant returns an assistant when the referenced agent exists") func resolveReturnsAssistantWhenAgentExists() throws {
        let store = ACPAgentStore(persistenceURL: persistenceURL)
        let connection = ACPAgentConnection(id: UUID(), name: "Test Agent", transport: .remote(url: URL(string: "https://example.com")!))
        try store.add(connection)
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "acp:\(connection.id.uuidString)"
        let resolved = AssistantBackendResolver.resolveActiveACPAssistant(
            siteID: "site-1", sourceDirectory: URL(fileURLWithPath: "/tmp/site-1"),
            containerControlProvider: { nil },
            agentStore: store, appSettings: settings
        )
        #expect(resolved != nil)
        #expect(resolved?.capabilities.providerName == "Test Agent")
    }
}
