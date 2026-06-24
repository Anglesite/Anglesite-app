import Testing
import Foundation
@testable import AnglesiteCore

struct SandboxControlClientTests {
    @Test("fake returns the configured session and records the token")
    func fakeStart() async throws {
        let session = SandboxSession(
            previewURL: URL(string: "https://preview.trycloudflare.com")!,
            mcpURL: URL(string: "https://mcp.trycloudflare.com/mcp")!)
        let fake = FakeSandboxControlClient(startResult: .success(session))
        let token = SessionToken.mint()
        let got = try await fake.start(
            siteID: "site-1",
            gitRemote: URL(string: "https://example.com/repo.git")!,
            gitRef: "main",
            token: token)
        #expect(got == session)
        #expect(await fake.startedToken == token)
    }

    @Test("fake propagates the configured error")
    func fakeStartError() async {
        let fake = FakeSandboxControlClient(startResult: .failure(.notProvisioned))
        await #expect(throws: SandboxControlError.notProvisioned) {
            _ = try await fake.start(
                siteID: "s", gitRemote: URL(string: "https://x/r.git")!,
                gitRef: "main", token: .mint())
        }
    }

    @Test("fake records stop calls")
    func fakeStop() async throws {
        let fake = FakeSandboxControlClient(
            startResult: .success(SandboxSession(
                previewURL: URL(string: "https://p")!, mcpURL: URL(string: "https://m/mcp")!)))
        try await fake.stop(siteID: "site-1")
        #expect(await fake.stopped == ["site-1"])
    }
}
