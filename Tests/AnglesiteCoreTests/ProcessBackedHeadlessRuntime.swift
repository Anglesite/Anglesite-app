import Foundation
@testable import AnglesiteCore

actor ProcessBackedHeadlessRuntime: HeadlessRuntime {
    nonisolated let mcpClient: MCPClient

    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let supervisor: ProcessSupervisor

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        supervisor: ProcessSupervisor = ProcessSupervisor()
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.supervisor = supervisor
        self.mcpClient = MCPClient(supervisor: supervisor)
    }

    func startHeadlessMCP(siteID: String, siteDirectory: URL) async -> Bool {
        var env = environment
        env["ANGLESITE_PROJECT_ROOT"] = siteDirectory.path
        do {
            try await mcpClient.start(
                executable: executable,
                arguments: arguments,
                environment: env,
                source: "test-mcp:\(siteID)",
                currentDirectoryURL: siteDirectory,
                restartPolicy: .never
            )
            return true
        } catch {
            return false
        }
    }

    func stop() async {
        await mcpClient.stop()
    }
}
