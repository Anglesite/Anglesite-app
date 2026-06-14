import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
        #expect(caps.supportsVision)  // macOS 27 on-device model accepts image attachments (C.7)
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

    @Test("generateStructured(imageURL:) describes an image into GeneratedAltText")
    func generateStructuredFromImage() async throws {
        guard modelAvailable() else { return }
        let imageURL = try Self.makeTempImage()
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let assistant = FoundationModelAssistant()
        // Proves the image→guided-generation path runs end-to-end. Exact content is model-dependent;
        // the contract is that it returns a valid `GeneratedAltText` (decorative ⇒ empty alt).
        let alt = try await assistant.generateStructured(
            prompt: "Generate concise alt text for this image.",
            imageURL: imageURL,
            context: makeContext(),
            resultType: GeneratedAltText.self
        )
        if alt.isDecorative {
            #expect(alt.altText.isEmpty)
        } else {
            #expect(!alt.altText.isEmpty)
        }
    }

    /// Writes a small two-color PNG to a temp file so the vision path has a real image to read.
    private static func makeTempImage() throws -> URL {
        let side = 64
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw AltTextImageError.context }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 16, y: 16, width: 32, height: 32))
        guard let image = ctx.makeImage() else { throw AltTextImageError.render }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alttext-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw AltTextImageError.destination }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw AltTextImageError.write }
        return url
    }

    private enum AltTextImageError: Error { case context, render, destination, write }

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
