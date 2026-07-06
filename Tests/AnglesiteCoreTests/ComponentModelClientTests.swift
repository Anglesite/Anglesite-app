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

    @Test("Tool errors surface as toolFailed") func toolErrors() async {
        let client = ComponentModelClient { _, _ in
            self.result(text: #"{"type":"anglesite:component-model-failed","reason":"read-failed"}"#, isError: true)
        }
        await #expect(throws: ComponentModelClient.ModelError.self) {
            _ = try await client.fetch(path: "src/components/Nope.astro")
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
}
