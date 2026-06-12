import Testing
import Foundation
@testable import AnglesiteCore

// FoundationModels (and thus the `generateStructured` / `Generable` surface) is only
// available on the Xcode-27 toolchain — see ContentAssistant.swift and #128.
#if compiler(>=6.4)
import FoundationModels

/// A minimal `Generable` value used to exercise the protocol's structured-output surface.
@Generable
struct StubGeneratedResult: Equatable {
    @Guide(description: "A generated title")
    var title: String
}

/// A second `Generable` type the stub can't produce — drives the error path.
@Generable
struct UnrelatedGeneratedResult: Equatable {
    @Guide(description: "A count")
    var count: Int
}
#endif

/// In-memory `ContentAssistant` conformer. Proves the protocol is usable as written: a backend
/// can satisfy the streaming, structured, and capabilities requirements with no provider SDK.
private struct StubAssistant: ContentAssistant {
    let chunks: [String]
    let capabilities: AssistantCapabilities
    #if compiler(>=6.4)
    let structured: StubGeneratedResult
    #endif

    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    #if compiler(>=6.4)
    func generateStructured<T: Generable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        guard let typed = structured as? T else {
            throw StubError.unsupportedResultType
        }
        return typed
    }

    enum StubError: Error { case unsupportedResultType }
    #endif
}

@Suite("ContentAssistant")
struct ContentAssistantTests {
    private static let testCapabilities = AssistantCapabilities(
        supportsStreaming: true,
        supportsStructuredOutput: true,
        supportsVision: false,
        supportsTools: true,
        maxContextTokens: 4096,
        providerName: "Test"
    )

    private func makeAssistant(chunks: [String] = []) -> StubAssistant {
        #if compiler(>=6.4)
        StubAssistant(chunks: chunks, capabilities: Self.testCapabilities, structured: StubGeneratedResult(title: "x"))
        #else
        StubAssistant(chunks: chunks, capabilities: Self.testCapabilities)
        #endif
    }

    private func makeContext(history: [AssistantMessage] = []) -> AssistantContext {
        AssistantContext(
            siteID: "site-1",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"),
            conversationHistory: history
        )
    }

    @Test("capabilities are exposed verbatim")
    func capabilitiesPassthrough() {
        let caps = makeAssistant().capabilities
        #expect(caps.providerName == "Test")
        #expect(caps.maxContextTokens == 4096)
        #expect(caps.supportsStreaming)
        #expect(caps.supportsStructuredOutput)
        #expect(caps.supportsTools)
        #expect(!caps.supportsVision)
    }

    @Test("generate streams chunks in order")
    func streamingPreservesOrder() async throws {
        let assistant = makeAssistant(chunks: ["Hello, ", "world", "!"])
        var collected = ""
        for try await chunk in try await assistant.generate(prompt: "hi", context: makeContext()) {
            collected += chunk
        }
        #expect(collected == "Hello, world!")
    }

    #if compiler(>=6.4)
    @Test("generateStructured returns the requested Generable type")
    func structuredReturnsTypedValue() async throws {
        let expected = StubGeneratedResult(title: "Generated")
        let assistant = StubAssistant(chunks: [], capabilities: Self.testCapabilities, structured: expected)
        let result = try await assistant.generateStructured(
            prompt: "make a title",
            context: makeContext(),
            resultType: StubGeneratedResult.self
        )
        #expect(result == expected)
    }

    @Test("generateStructured surfaces a backend failure")
    func structuredPropagatesError() async {
        let assistant = StubAssistant(
            chunks: [],
            capabilities: Self.testCapabilities,
            structured: StubGeneratedResult(title: "x")
        )
        await #expect(throws: StubAssistant.StubError.self) {
            _ = try await assistant.generateStructured(
                prompt: "give me a count",
                context: makeContext(),
                resultType: UnrelatedGeneratedResult.self
            )
        }
    }
    #endif

    @Test("AssistantMessage is value-equatable")
    func messageEquatable() {
        let a = AssistantMessage(role: .user, content: "hi")
        #expect(a == AssistantMessage(role: .user, content: "hi"))
        #expect(a != AssistantMessage(role: .assistant, content: "hi"))
        #expect(a != AssistantMessage(role: .user, content: "bye"))
    }

    @Test("AssistantContext carries optional fields and history")
    func contextConstruction() {
        let history = [AssistantMessage(role: .system, content: "you are helpful")]
        let context = AssistantContext(
            siteID: "abc",
            siteDirectory: URL(fileURLWithPath: "/tmp/abc"),
            currentPageRoute: "/about",
            currentPageContent: "# About",
            selectedElementSelector: .object(["tag": .string("h1"), "index": .int(0)]),
            conversationHistory: history
        )
        #expect(context.siteID == "abc")
        #expect(context.currentPageRoute == "/about")
        #expect(context.currentPageContent == "# About")
        #expect(context.selectedElementSelector == .object(["tag": .string("h1"), "index": .int(0)]))
        #expect(context.conversationHistory == history)
    }
}
