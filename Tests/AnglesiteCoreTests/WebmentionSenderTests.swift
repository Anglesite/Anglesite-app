import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WebmentionSender")
struct WebmentionSenderTests {
    private let source = URL(string: "https://mysite.test/posts/hello/")!
    private let target = URL(string: "https://target.example/post")!
    private let endpoint = URL(string: "https://target.example/webmention")!

    private actor CallRecorder {
        private(set) var requests: [URLRequest] = []
        func record(_ request: URLRequest) { requests.append(request) }
    }

    @Test("discovers the endpoint and POSTs source+target, reporting the status code")
    func successfulSend() async throws {
        let recorder = CallRecorder()
        let endpointURL = endpoint
        let targetURL = target
        let outcome = await WebmentionSender.send(source: source, target: target, transport: { request in
            await recorder.record(request)
            if request.httpMethod == "POST" {
                let http = HTTPURLResponse(url: endpointURL, statusCode: 202, httpVersion: nil, headerFields: nil)!
                return (Data(), http)
            }
            let http = HTTPURLResponse(
                url: targetURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Link": "<\(endpointURL.absoluteString)>; rel=\"webmention\""]
            )!
            return (Data(), http)
        })

        #expect(outcome == .sent(endpoint: endpoint, statusCode: 202))
        let requests = await recorder.requests
        #expect(requests.count == 2)
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[1].url == endpoint)
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(data: requests[1].httpBody ?? Data(), encoding: .utf8)
        #expect(body == "source=https%3A%2F%2Fmysite.test%2Fposts%2Fhello%2F&target=https%3A%2F%2Ftarget.example%2Fpost")
    }

    @Test("no discovered endpoint sends no POST")
    func noEndpointSendsNothing() async throws {
        let recorder = CallRecorder()
        let targetURL = target
        let outcome = await WebmentionSender.send(source: source, target: target, transport: { request in
            await recorder.record(request)
            let http = HTTPURLResponse(url: targetURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("<html>no endpoint</html>".utf8), http)
        })
        #expect(outcome == .noEndpointDiscovered)
        let requests = await recorder.requests
        #expect(requests.count == 1) // only the discovery GET, no POST
    }

    @Test("a non-2xx endpoint response maps to .requestFailed")
    func failedPost() async throws {
        let endpointURL = endpoint
        let targetURL = target
        let outcome = await WebmentionSender.send(source: source, target: target, transport: { request in
            if request.httpMethod == "POST" {
                let http = HTTPURLResponse(url: endpointURL, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (Data(), http)
            }
            let http = HTTPURLResponse(
                url: targetURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Link": "<\(endpointURL.absoluteString)>; rel=\"webmention\""]
            )!
            return (Data(), http)
        })
        guard case .requestFailed = outcome else {
            Issue.record("expected .requestFailed, got \(outcome)")
            return
        }
    }

    @Test("a discovery-phase network error maps to .requestFailed")
    func discoveryThrows() async throws {
        struct Boom: Error {}
        let outcome = await WebmentionSender.send(source: source, target: target, transport: { _ in throw Boom() })
        guard case .requestFailed = outcome else {
            Issue.record("expected .requestFailed, got \(outcome)")
            return
        }
    }
}
