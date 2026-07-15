import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WebmentionSendCommand")
struct WebmentionSendCommandTests {
    private func makeSite() throws -> (root: URL, siteDirectory: URL, configDirectory: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webmention-send-command-\(UUID().uuidString)", isDirectory: true)
        let siteDirectory = root.appendingPathComponent("Source", isDirectory: true)
        let configDirectory = root.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let post = siteDirectory.appendingPathComponent("src/content/posts/hello.md")
        try FileManager.default.createDirectory(at: post.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        ---
        publishDate: 2026-06-29
        ---
        Links to https://one.example/target and https://two.example/target.
        """.utf8).write(to: post)
        return (root, siteDirectory, configDirectory)
    }

    /// A transport that reports every target's endpoint as `<target>/webmention`, and accepts
    /// every POST with 202 unless the endpoint's target is listed in `failing`.
    private func transport(failing: Set<String> = []) -> WebmentionEndpointDiscovery.Transport {
        { request in
            let url = request.url!
            if request.httpMethod == "POST" {
                // `deletingLastPathComponent()` always returns a directory-style URL (trailing
                // slash), even though `failing`'s entries are plain target strings with none —
                // strip it before comparing so a POST to <target>/webmention is correctly
                // recognized as belonging to `target`.
                var targetForEndpoint = url.deletingLastPathComponent().absoluteString
                if targetForEndpoint.hasSuffix("/") { targetForEndpoint.removeLast() }
                let status = failing.contains(targetForEndpoint) ? 500 : 202
                return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            let endpoint = url.appendingPathComponent("webmention")
            let http = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Link": "<\(endpoint.absoluteString)>; rel=\"webmention\""]
            )!
            return (Data(), http)
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    @Test("sends every pending target and persists them to the sent log")
    func sendsAndPersists() async throws {
        let (root, siteDirectory, configDirectory) = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        let logCenter = LogCenter()
        let command = WebmentionSendCommand(
            transport: transport(),
            logCenter: logCenter,
            now: { Date(timeIntervalSince1970: 1_782_777_600) }
        )

        await command.send(
            siteID: "site1",
            siteDirectory: siteDirectory,
            configDirectory: configDirectory,
            siteBase: URL(string: "https://mysite.test")!
        )

        let log = WebmentionSentLog.load(from: configDirectory)
        #expect(log?.sent.count == 2)
        #expect(Set(log?.sent.map(\.target.absoluteString) ?? []) == [
            "https://one.example/target", "https://two.example/target",
        ])

        let lines = await logCenter.snapshot()
        #expect(lines.contains { $0.source == "webmention:site1" && $0.text.contains("sending 2 webmention") })
        #expect(lines.filter { $0.source == "webmention:site1" && $0.text.contains("sent ") }.count == 2)
    }

    @Test("a second run does not resend already-sent pairs")
    func skipsAlreadySentPairs() async throws {
        let (root, siteDirectory, configDirectory) = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = Counter()
        let baseTransport = transport()
        let counting: WebmentionEndpointDiscovery.Transport = { request in
            if request.httpMethod == "POST" { await counter.increment() }
            return try await baseTransport(request)
        }
        let command = WebmentionSendCommand(transport: counting, logCenter: LogCenter())
        let siteBase = URL(string: "https://mysite.test")!

        await command.send(siteID: "site1", siteDirectory: siteDirectory, configDirectory: configDirectory, siteBase: siteBase)
        var count = await counter.value
        #expect(count == 2)

        await command.send(siteID: "site1", siteDirectory: siteDirectory, configDirectory: configDirectory, siteBase: siteBase)
        count = await counter.value
        #expect(count == 2) // no new POSTs on the second run
    }

    @Test("a failed send is not persisted, so it's retried on the next run")
    func failedSendIsRetried() async throws {
        let (root, siteDirectory, configDirectory) = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = WebmentionSendCommand(
            transport: transport(failing: ["https://one.example/target"]),
            logCenter: LogCenter()
        )

        await command.send(
            siteID: "site1", siteDirectory: siteDirectory, configDirectory: configDirectory,
            siteBase: URL(string: "https://mysite.test")!
        )

        let log = WebmentionSentLog.load(from: configDirectory)
        #expect(log?.sent.map(\.target.absoluteString) == ["https://two.example/target"])
    }

    @Test("a site with no outbound links sends nothing and writes no log")
    func noPlanEntriesIsANoop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webmention-empty-\(UUID().uuidString)", isDirectory: true)
        let siteDirectory = root.appendingPathComponent("Source", isDirectory: true)
        let configDirectory = root.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: siteDirectory.appendingPathComponent("src/content"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let command = WebmentionSendCommand(transport: transport(), logCenter: LogCenter())
        await command.send(
            siteID: "site1", siteDirectory: siteDirectory, configDirectory: configDirectory,
            siteBase: URL(string: "https://mysite.test")!
        )

        #expect(WebmentionSentLog.load(from: configDirectory) == nil)
    }
}
