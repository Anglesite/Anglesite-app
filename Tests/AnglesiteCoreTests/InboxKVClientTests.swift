import Testing
import Foundation
@testable import AnglesiteCore

struct InboxKVClientTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    @Test("lists staged submissions by fetching each key's value")
    func listsStagedSubmissions() async throws {
        let keysBody = Data("""
        {"success": true, "result": [{"name": "inbox:abc"}, {"name": "inbox:def"}]}
        """.utf8)
        let submissionA = Data("""
        {"id": "abc", "subject": "Hello", "from": "a@example.com", "message": "Hi there", "receivedAt": "2026-07-10T00:00:00Z"}
        """.utf8)
        let submissionB = Data("""
        {"id": "def", "subject": "Question", "from": "b@example.com", "message": "How do I...", "receivedAt": "2026-07-10T00:01:00Z"}
        """.utf8)

        let client = InboxKVClient(accountID: "acct1", namespaceID: "ns1", apiToken: "token", transport: { request in
            if request.url!.path.hasSuffix("/keys") { return (keysBody, Self.response(200)) }
            if request.url!.path.hasSuffix("/values/inbox:abc") { return (submissionA, Self.response(200)) }
            if request.url!.path.hasSuffix("/values/inbox:def") { return (submissionB, Self.response(200)) }
            return (Data(), Self.response(404))
        })

        let submissions = try await client.listStagedSubmissions()
        #expect(submissions.count == 2)
        #expect(submissions.contains { $0.id == "abc" && $0.subject == "Hello" })
        #expect(submissions.contains { $0.id == "def" && $0.subject == "Question" })
    }

    @Test("follows result_info.cursor across pages when listing keys")
    func followsCursorAcrossPages() async throws {
        let page1 = Data("""
        {"success": true, "result": [{"name": "inbox:abc"}], "result_info": {"count": 1, "cursor": "next-page-cursor"}}
        """.utf8)
        let page2 = Data("""
        {"success": true, "result": [{"name": "inbox:def"}], "result_info": {"count": 1, "cursor": ""}}
        """.utf8)
        let submissionA = Data("""
        {"id": "abc", "subject": "Hello", "from": "a@example.com", "message": "Hi there", "receivedAt": "2026-07-10T00:00:00Z"}
        """.utf8)
        let submissionB = Data("""
        {"id": "def", "subject": "Question", "from": "b@example.com", "message": "How do I...", "receivedAt": "2026-07-10T00:01:00Z"}
        """.utf8)

        let client = InboxKVClient(accountID: "acct1", namespaceID: "ns1", apiToken: "token", transport: { request in
            let query = request.url?.query ?? ""
            if request.url!.path.hasSuffix("/keys") {
                return query.contains("cursor=next-page-cursor") ? (page2, Self.response(200)) : (page1, Self.response(200))
            }
            if request.url!.path.hasSuffix("/values/inbox:abc") { return (submissionA, Self.response(200)) }
            if request.url!.path.hasSuffix("/values/inbox:def") { return (submissionB, Self.response(200)) }
            return (Data(), Self.response(404))
        })

        let submissions = try await client.listStagedSubmissions()
        #expect(submissions.count == 2)
        #expect(submissions.contains { $0.id == "abc" })
        #expect(submissions.contains { $0.id == "def" })
    }

    @Test("a single page response with no cursor still works and does not loop forever")
    func singlePageWithoutCursorWorks() async throws {
        let keysBody = Data("""
        {"success": true, "result": [{"name": "inbox:abc"}]}
        """.utf8)
        let submissionA = Data("""
        {"id": "abc", "subject": "Hello", "from": "a@example.com", "message": "Hi there", "receivedAt": "2026-07-10T00:00:00Z"}
        """.utf8)

        let client = InboxKVClient(accountID: "acct1", namespaceID: "ns1", apiToken: "token", transport: { request in
            if request.url!.path.hasSuffix("/keys") { return (keysBody, Self.response(200)) }
            if request.url!.path.hasSuffix("/values/inbox:abc") { return (submissionA, Self.response(200)) }
            return (Data(), Self.response(404))
        })

        let submissions = try await client.listStagedSubmissions()
        #expect(submissions == [
            InboxKVClient.Submission(id: "abc", subject: "Hello", from: "a@example.com", message: "Hi there",
                                      receivedAt: "2026-07-10T00:00:00Z")
        ])
    }

    @Test("skips a key whose value fails to decode instead of failing the whole pull")
    func skipsMalformedEntries() async throws {
        let keysBody = Data("""
        {"success": true, "result": [{"name": "inbox:bad"}, {"name": "inbox:ok"}]}
        """.utf8)
        let okSubmission = Data("""
        {"id": "ok", "subject": "Fine", "from": "a@example.com", "message": "ok", "receivedAt": "2026-07-10T00:00:00Z"}
        """.utf8)

        let client = InboxKVClient(accountID: "acct1", namespaceID: "ns1", apiToken: "token", transport: { request in
            if request.url!.path.hasSuffix("/keys") { return (keysBody, Self.response(200)) }
            if request.url!.path.hasSuffix("/values/inbox:bad") { return (Data("not json".utf8), Self.response(200)) }
            if request.url!.path.hasSuffix("/values/inbox:ok") { return (okSubmission, Self.response(200)) }
            return (Data(), Self.response(404))
        })

        let submissions = try await client.listStagedSubmissions()
        #expect(submissions == [
            InboxKVClient.Submission(id: "ok", subject: "Fine", from: "a@example.com", message: "ok",
                                      receivedAt: "2026-07-10T00:00:00Z")
        ])
    }

    @Test("throws unauthorized on a 401/403 listing keys")
    func throwsUnauthorized() async {
        let client = InboxKVClient(accountID: "acct1", namespaceID: "ns1", apiToken: "bad", transport: { _ in
            (Data(), Self.response(403))
        })
        await #expect(throws: CloudflareError.unauthorized) {
            _ = try await client.listStagedSubmissions()
        }
    }

    @Test("deleteSubmission issues a DELETE to the value endpoint")
    func deletesSubmission() async throws {
        let captured = CapturedRequest()
        let client = InboxKVClient(accountID: "acct1", namespaceID: "ns1", apiToken: "token", transport: { request in
            await captured.set(request)
            return (Data(), Self.response(200))
        })
        try await client.deleteSubmission(id: "abc")
        let request = await captured.value
        #expect(request?.httpMethod == "DELETE")
        #expect(request?.url?.path.hasSuffix("/values/inbox:abc") == true)
    }
}

/// Actor wrapper so the transport closure (which must be `@Sendable`) can hand a captured
/// `URLRequest` back to the test body without a data race.
private actor CapturedRequest {
    private(set) var value: URLRequest?
    func set(_ request: URLRequest) { value = request }
}
