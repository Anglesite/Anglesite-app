import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct HTTPSandboxControlClientTests {
    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SandboxStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test("start posts and parses the two URLs")
    func startParses() async throws {
        SandboxStubURLProtocol.handler = { req in
            #expect(req.url?.path == "/start")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer api-tok")
            let body = #"{"previewURL":"https://p.trycloudflare.com","mcpURL":"https://m.trycloudflare.com/mcp"}"#
            return (200, Data(body.utf8))
        }
        let client = HTTPSandboxControlClient(
            workerBaseURL: URL(string: "https://worker.example.workers.dev")!,
            apiToken: "api-tok", urlSession: session())
        let s = try await client.start(
            siteID: "s1", gitRemote: URL(string: "https://x/r.git")!,
            gitRef: "main", token: SessionToken(value: "t"))
        #expect(s.previewURL == URL(string: "https://p.trycloudflare.com")!)
        #expect(s.mcpURL == URL(string: "https://m.trycloudflare.com/mcp")!)
    }

    @Test("401 maps to .unauthorized")
    func unauthorized() async {
        SandboxStubURLProtocol.handler = { _ in (401, Data()) }
        let client = HTTPSandboxControlClient(
            workerBaseURL: URL(string: "https://w.workers.dev")!, apiToken: "x", urlSession: session())
        await #expect(throws: SandboxControlError.unauthorized) {
            _ = try await client.start(
                siteID: "s", gitRemote: URL(string: "https://x/r.git")!, gitRef: "main", token: SessionToken(value: "t"))
        }
    }

    @Test("status posts and parses readiness")
    func statusParses() async throws {
        SandboxStubURLProtocol.handler = { req in
            #expect(req.url?.path == "/status")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer api-tok")
            let body = #"{"siteID":"s1","previewReady":true,"mcpReady":false}"#
            return (200, Data(body.utf8))
        }
        let client = HTTPSandboxControlClient(
            workerBaseURL: URL(string: "https://worker.example.workers.dev")!,
            apiToken: "api-tok", urlSession: session())
        let status = try await client.status(siteID: "s1")
        #expect(status == SandboxStatus(siteID: "s1", previewReady: true, mcpReady: false))
        #expect(status.isReady == false)
    }
}

/// Minimal URLProtocol stub for offline HTTP-client tests (sandbox control client variant).
/// Named `SandboxStubURLProtocol` to avoid redeclaration conflict with the queue-based
/// `StubURLProtocol` already defined in `HTTPTransportTests.swift`.
final class SandboxStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let (status, data) = handler(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
