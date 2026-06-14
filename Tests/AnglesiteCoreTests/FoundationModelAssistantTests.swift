import Testing
import Foundation
@testable import AnglesiteCore

// Gated like the type under test (#128). Capability/tier assertions run on any toolchain≥6.4;
// the generate/generateStructured tests are live-model and skip when unavailable.
// TODO(#104/#161): migrate the live tests to the mock LanguageModel session once #104 lands.
#if compiler(>=6.4)
import FoundationModels

@Suite("FoundationModelAssistant")
struct FoundationModelAssistantTests {

    private func makeContext() -> AssistantContext {
        AssistantContext(siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
    }

    private func modelAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    // MARK: Capabilities / tier (no model required)

    @Test("on-device tier advertises the on-device capabilities")
    func onDeviceCapabilities() {
        let caps = FoundationModelAssistant(tier: .onDevice).capabilities
        #expect(caps.providerName == "On-Device")
        #expect(caps.maxContextTokens == 4_096)
        #expect(caps.supportsStreaming)
        #expect(caps.supportsStructuredOutput)
        #expect(!caps.supportsTools)
        #expect(!caps.supportsVision)
    }

    @Test("PCC tier advertises a larger context window and PCC provider name")
    func pccCapabilities() {
        let caps = FoundationModelAssistant(tier: .privateCloudCompute).capabilities
        #expect(caps.providerName == "Private Cloud Compute")
        #expect(caps.maxContextTokens == 32_768)
    }

    @Test("default tier is on-device")
    func defaultTierIsOnDevice() {
        #expect(FoundationModelAssistant().capabilities.providerName == "On-Device")
    }

    @Test("PCC-tier assistant constructs and remains usable (falls back to on-device)")
    func pccConstructsAndIsUsable() {
        // `capabilities` is a nonisolated var, so it reads synchronously off the actor.
        let assistant = FoundationModelAssistant(tier: .privateCloudCompute)
        #expect(assistant.capabilities.maxContextTokens == 32_768)
    }

    // MARK: Error path (meaningful only on a host WITHOUT the model)

    @Test("generate surfaces AssistantError.unavailable when the model is absent")
    func generateUnavailableSurfacesError() async {
        guard !modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        do {
            _ = try await assistant.generate(prompt: "hi", context: makeContext())
            Issue.record("Expected AssistantError.unavailable but generate succeeded")
        } catch let error as AssistantError {
            guard case .unavailable = error else {
                Issue.record("Expected AssistantError.unavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected non-AssistantError: \(error)")
        }
    }

    // MARK: Live paths (skip when the model is unavailable)

    @Test("generate streams non-empty text")
    func generateStreamsText() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        var collected = ""
        for try await chunk in try await assistant.generate(prompt: "Say hello in one short sentence.", context: makeContext()) {
            collected += chunk
        }
        #expect(!collected.isEmpty)
    }

    @Test("generateStructured returns the requested Generable type")
    func generateStructuredReturnsType() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        let result = try await assistant.generateStructured(
            prompt: "Generate page metadata for a contact page.",
            context: makeContext(),
            resultType: GeneratedPageMeta.self
        )
        #expect(!result.title.isEmpty)
    }

    // MARK: ConversationalAssistant conformance (C.9 — MAS chat backend)

    @Test("is usable as any ConversationalAssistant")
    func conformsToConversationalAssistant() {
        // Compile-time + runtime proof that the on-device assistant can back `ChatModel`,
        // whose dependency is `any ConversationalAssistant`.
        let assistant: any ConversationalAssistant = FoundationModelAssistant(tier: .onDevice)
        #expect(assistant.capabilities.providerName == "On-Device")
    }

    @Test("resetSession discards the cached session and is safe when none is cached")
    func resetSessionIsSafe() async {
        let assistant = FoundationModelAssistant()
        await assistant.resetSession()  // no turn in flight, no session cached yet — must be harmless
    }

    @Test("cancel with no active turn is a safe no-op")
    func cancelWithoutTurnIsSafe() async {
        let assistant = FoundationModelAssistant()
        await assistant.cancel()  // nothing in flight — must be harmless
    }

    @Test("converse surfaces AssistantError.unavailable when the model is absent")
    func converseUnavailableSurfacesError() async {
        guard !modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        do {
            _ = try await assistant.converse(prompt: "hi", context: makeContext())
            Issue.record("Expected AssistantError.unavailable but converse succeeded")
        } catch let error as AssistantError {
            guard case .unavailable = error else {
                Issue.record("Expected AssistantError.unavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected non-AssistantError: \(error)")
        }
    }

    @Test("converse opens with .started, streams .textDelta, and ends with .turnComplete")
    func converseEmitsLifecycleEvents() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(
            prompt: "Say hello in one short sentence.",
            context: makeContext()
        ) {
            events.append(event)
        }

        // First event is the turn marker.
        guard case .started = events.first else {
            Issue.record("Expected first event to be .started, got \(String(describing: events.first))")
            return
        }
        // At least one text chunk arrived.
        let deltas = events.filter { if case .textDelta = $0 { return true } else { return false } }
        #expect(!deltas.isEmpty)
        // Terminal event is .turnComplete (no in-band failure).
        guard case .turnComplete = events.last else {
            Issue.record("Expected last event to be .turnComplete, got \(String(describing: events.last))")
            return
        }
    }

    @Test("converse retains conversation history across turns")
    func converseRemembersAcrossTurns() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        let context = makeContext()

        // Turn 1: plant a fact. Drain the stream fully so the turn completes.
        for await _ in try await assistant.converse(
            prompt: "Remember this code word: Falkor. Reply with just 'ok'.",
            context: context
        ) {}

        // Turn 2: recall is only possible if the session (and its history) persisted across turns —
        // the bug this guards against created a fresh, memoryless session per turn.
        var reply = ""
        for await event in try await assistant.converse(
            prompt: "What is the code word I gave you? Reply with only the word.",
            context: context
        ) {
            if case .textDelta(let text) = event { reply += text }
        }
        #expect(reply.localizedCaseInsensitiveContains("Falkor"))
    }

    @Test("cancel mid-stream yields .cancelled and ends the turn")
    func cancelMidStreamYieldsCancelled() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(
            prompt: "Write a long, detailed, multi-paragraph history of typography.",
            context: makeContext()
        ) {
            events.append(event)
            // Cancel as soon as the model starts emitting text — the turn must wind down to
            // `.cancelled`, not run to `.turnComplete`.
            if case .textDelta = event { await assistant.cancel() }
        }
        guard case .cancelled = events.last else {
            Issue.record("Expected last event to be .cancelled, got \(String(describing: events.last))")
            return
        }
    }
}
#endif
