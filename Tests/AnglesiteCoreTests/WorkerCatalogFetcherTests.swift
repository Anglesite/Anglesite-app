import Testing
import Foundation
@testable import AnglesiteCore

/// Stub `URLProtocol` returning a canned status/body for every request, so
/// `WorkerCatalogFetcher` can be exercised without a real network call — mirrors
/// `FreedesignmdCatalogTests`' `FreedesignmdStubURLProtocol`.
private final class WorkerCatalogStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var shouldFailToLoad = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.shouldFailToLoad {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkerCatalogStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// .serialized: tests share WorkerCatalogStubURLProtocol's mutable static status/body/failure
// flag, which would race under Swift Testing's default parallel execution.
@Suite(.serialized) struct WorkerCatalogFetcherTests {
    private let sampleJSON = """
    {
      "workers": [
        {
          "id": "webmention",
          "displayName": "Webmentions",
          "description": "Receive and verify webmentions for posts",
          "group": "social",
          "binding": { "kind": "componentTied", "componentIDs": ["webmention-form"] },
          "resources": { "needsD1": true, "needsKV": true, "needsR2": false }
        }
      ]
    }
    """

    private func tempCacheURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("worker-catalog-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("worker-catalog-cache.json")
    }

    @Test("fetches, parses, and writes the cache file on success")
    func fetchesAndCachesOnSuccess() async throws {
        WorkerCatalogStubURLProtocol.shouldFailToLoad = false
        WorkerCatalogStubURLProtocol.statusCode = 200
        WorkerCatalogStubURLProtocol.body = sampleJSON
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.map(\.id) == ["webmention"])
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("falls back to the cached catalog when the fetch fails")
    func fallsBackToCacheOnFetchFailure() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sampleJSON.utf8).write(to: cacheURL)

        WorkerCatalogStubURLProtocol.shouldFailToLoad = true
        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.map(\.id) == ["webmention"])
    }

    @Test("returns an empty catalog when the fetch fails and there is no cache")
    func returnsEmptyWhenNoCacheAndFetchFails() async {
        WorkerCatalogStubURLProtocol.shouldFailToLoad = true
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.isEmpty)
    }

    @Test("returns an empty catalog on a non-2xx response with no cache")
    func returnsEmptyOnBadStatusWithNoCache() async {
        WorkerCatalogStubURLProtocol.shouldFailToLoad = false
        WorkerCatalogStubURLProtocol.statusCode = 404
        WorkerCatalogStubURLProtocol.body = "not found"
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.isEmpty)
    }
}
