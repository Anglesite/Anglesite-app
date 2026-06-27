import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Records `create_page` / `create_post` calls and vends configurable Results — the content-side
/// analogue of `FakeOperations`. Each test sets up the result it expects and reads back the
/// recorded calls (`pageCalls`/`postCalls`, or just `.count`) after the intent runs.
///
/// Class (not struct) so the override-scoped reference semantics let every test see the same
/// mutated instance — the intent's `ContentOperationsOverride.scoped ?? content` reads the captured
/// instance directly rather than a copy.
///
/// Thread-safety: `@unchecked Sendable` is safe only because each test uses its own instance scoped
/// to a single Task (via `ContentOperationsOverride.$scoped.withValue`) and the root
/// `@Suite("AppIntents", .serialized)` prevents inter-suite parallel access. Sharing a single
/// instance across concurrent tasks would race silently — don't.
final class FakeContentOps: ContentOperationsService, @unchecked Sendable {
    var pageResult: ContentCreateResult = .created(filePath: "src/pages/x.astro", identifier: "/x")
    var postResult: ContentCreateResult = .created(filePath: "src/content/posts/x.md", identifier: "x")
    var typedResult: ContentCreateResult = .created(filePath: "src/content/notes/x.md", identifier: "x")
    private(set) var pageCalls: [(siteID: String, name: String, route: String?)] = []
    private(set) var postCalls: [(siteID: String, title: String, collection: String?, slug: String?)] = []
    private(set) var typedCalls: [(siteID: String, typeID: String, title: String)] = []

    func createPage(siteID: String, name: String, route: String?, onProgress: ProgressHandler?) async -> ContentCreateResult {
        pageCalls.append((siteID, name, route))
        return pageResult
    }

    func createPost(siteID: String, title: String, collection: String?, slug: String?, onProgress: ProgressHandler?) async -> ContentCreateResult {
        postCalls.append((siteID, title, collection, slug))
        return postResult
    }

    func createTyped(siteID: String, typeID: String, title: String, onProgress: ProgressHandler?) async -> ContentCreateResult {
        typedCalls.append((siteID, typeID, title))
        return typedResult
    }
}
