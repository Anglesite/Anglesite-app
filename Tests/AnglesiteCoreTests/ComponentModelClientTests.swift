import Testing
import Foundation
@testable import AnglesiteCore

struct ComponentModelClientTests {
    private func result(text: String, isError: Bool = false) -> MCPClient.ToolCallResult {
        MCPClient.ToolCallResult(content: [.init(type: "text", text: text)], isError: isError)
    }

    @Test("Fetch calls get_component_model and decodes the model") func fetchDecodes() async throws {
        let client = ComponentModelClient { name, args in
            #expect(name == "get_component_model")
            #expect(args == .object(["path": .string("src/components/Card.astro")]))
            return self.result(text: ComponentModelTests.fixture)
        }
        let model = try await client.fetch(path: "src/components/Card.astro")
        #expect(model.path == "src/components/Card.astro")
    }

    @Test("Tool errors decode the plugin's reason/detail envelope into toolFailed") func toolErrors() async throws {
        let client = ComponentModelClient { _, _ in
            self.result(
                text: #"{"type":"anglesite:component-model-failed","reason":"parse-failed","detail":"parse Card.astro: Unexpected token"}"#,
                isError: true
            )
        }
        do {
            _ = try await client.fetch(path: "src/components/Nope.astro")
            Issue.record("expected throw")
        } catch let error as ComponentModelClient.ModelError {
            #expect(error == .toolFailed(reason: "parse-failed", detail: "parse Card.astro: Unexpected token"))
        }
    }

    @Test("A tool error whose text isn't the plugin's envelope falls back to reason \"unknown\"") func toolErrorFallback() async throws {
        let client = ComponentModelClient { _, _ in self.result(text: "boom", isError: true) }
        do {
            _ = try await client.fetch(path: "x.astro")
            Issue.record("expected throw")
        } catch let error as ComponentModelClient.ModelError {
            #expect(error == .toolFailed(reason: "unknown", detail: "boom"))
        }
    }

    @Test("Garbage payloads surface as decodeFailed") func garbageFails() async {
        let client = ComponentModelClient { _, _ in self.result(text: "not json") }
        do {
            _ = try await client.fetch(path: "x.astro")
            Issue.record("expected throw")
        } catch let error as ComponentModelClient.ModelError {
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test("friendlyMessage passes a parse-failed diagnostic through verbatim, for the Source-tab banner") func friendlyMessageParseFailed() {
        let error = ComponentModelClient.ModelError.toolFailed(reason: "parse-failed", detail: "parse Card.astro: Unexpected token")
        #expect(error.friendlyMessage == "parse Card.astro: Unexpected token")
    }

    @Test("friendlyMessage summarizes other reasons instead of dumping the raw error") func friendlyMessageOtherReasons() {
        #expect(ComponentModelClient.ModelError.notConnected.friendlyMessage == "Site is not running yet.")
        #expect(ComponentModelClient.ModelError.toolFailed(reason: "read-failed", detail: "permission denied").friendlyMessage
            == "Couldn't read this component file: permission denied")
        #expect(ComponentModelClient.ModelError.toolFailed(reason: "internal-error", detail: "boom").friendlyMessage
            == "Something went wrong loading this component: boom")
        #expect(!ComponentModelClient.ModelError.decodeFailed("keyNotFound(...)").friendlyMessage.contains("keyNotFound"))
    }
}
