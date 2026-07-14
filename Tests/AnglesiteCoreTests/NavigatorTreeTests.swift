import Testing
import Foundation
@testable import AnglesiteCore

struct NavigatorTreeTests {
    @Test("post route derives /collection/slug/")
    func postRouteDerivation() {
        let post = SiteContentGraph.Post(
            id: "s:post:hello-world", siteID: "s", collection: "blog", slug: "hello-world",
            title: "Hello", draft: false, publishDate: nil, tags: [],
            filePath: "/tmp/hello-world.md", lastModified: Date(timeIntervalSince1970: 0))
        #expect(postRoute(for: post) == "/blog/hello-world/")
    }
}
