import Testing
import Foundation
@testable import AnglesiteCore

struct RemoteSandboxSiteRuntimeTests {
    private func makeRuntime(
        _ result: Result<SandboxSession, SandboxControlError>,
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { _, _ in }
    ) -> (RemoteSandboxSiteRuntime, FakeSandboxControlClient) {
        let fake = FakeSandboxControlClient(startResult: result)
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = RemoteSandboxSiteRuntime(
            gitRemote: URL(string: "https://example.com/repo.git")!,
            gitRef: "main",
            control: fake,
            mcpClient: mcp,
            mintToken: { SessionToken(value: "fixedtoken") },
            connect: connect)
        return (rt, fake)
    }

    private static let ok = SandboxSession(
        previewURL: URL(string: "https://preview.trycloudflare.com")!,
        mcpURL: URL(string: "https://mcp.trycloudflare.com/mcp")!)

    @Test("start settles to .ready with the preview URL")
    func startReady() async {
        let (rt, _) = makeRuntime(.success(Self.ok))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(await rt.state == .ready(siteID: "s1", url: Self.ok.previewURL))
    }

    @Test("start connects the MCP client to the mcp tunnel URL")
    func startConnectsMCP() async {
        let box = ConnectedURLBox()
        let (rt, _) = makeRuntime(.success(Self.ok), connect: { _, url in await box.set(url) })
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(await box.url == Self.ok.mcpURL)
    }

    @Test("control failure settles to .failed")
    func startFailed() async {
        let (rt, _) = makeRuntime(.failure(.startFailed("clone failed")))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        if case .failed(let id, let msg) = await rt.state {
            #expect(id == "s1")
            #expect(msg.contains("clone failed"))
        } else { Issue.record("expected .failed, got \(await rt.state)") }
    }

    @Test("stop calls the control client and returns to .idle")
    func stop() async {
        let (rt, fake) = makeRuntime(.success(Self.ok))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        await rt.stop()
        #expect(await rt.state == .idle)
        #expect(await fake.stopped == ["s1"])
    }

    @Test("observe yields starting then ready")
    func observeTransitions() async {
        let (rt, _) = makeRuntime(.success(Self.ok))
        let stream = await rt.observe()
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        var seen: [SiteRuntimeState] = []
        for await s in stream { seen.append(s); if case .ready = s { break } }
        #expect(seen.contains(.starting(siteID: "s1")))
        #expect(seen.last == .ready(siteID: "s1", url: Self.ok.previewURL))
    }
}

/// Test-only sink so the injected `connect` closure can record the URL it was handed.
actor ConnectedURLBox { private(set) var url: URL?; func set(_ u: URL) { url = u } }
