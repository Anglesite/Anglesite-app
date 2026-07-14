import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ACPAgentConnectionTests {
    @Test func stdioConnectionRoundTripsThroughJSON() throws {
        let original = ACPAgentConnection(
            id: UUID(),
            name: "Local Agent",
            transport: .stdio(command: "claude-code-acp", arguments: ["--flag"])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ACPAgentConnection.self, from: data)
        #expect(decoded == original)
    }

    @Test func remoteConnectionRoundTripsThroughJSON() throws {
        let original = ACPAgentConnection(
            id: UUID(),
            name: "Hosted Agent",
            transport: .remote(url: URL(string: "https://agent.example.com/acp")!)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ACPAgentConnection.self, from: data)
        #expect(decoded == original)
    }
}
