import Testing
import Foundation
@testable import AnglesiteCore

struct NavigatorTreeTests {
    private func page(_ route: String, title: String?) -> SiteContentGraph.Page {
        SiteContentGraph.Page(id: "s:page:\(route)", siteID: "s", route: route,
            filePath: "/tmp\(route).astro", title: title, lastModified: Date(timeIntervalSince1970: 0))
    }
    private func post(_ collection: String, _ slug: String, _ title: String) -> SiteContentGraph.Post {
        SiteContentGraph.Post(id: "s:post:\(slug)", siteID: "s", collection: collection, slug: slug,
            title: title, draft: false, publishDate: nil, tags: [],
            filePath: "/tmp/\(slug).md", lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("post route derives /collection/slug/")
    func postRouteDerivation() {
        #expect(postRoute(for: post("blog", "hello-world", "Hello")) == "/blog/hello-world/")
    }

    @Test("sections appear in canonical order and only when non-empty")
    func sectionOrderAndEmpties() {
        let sections = buildNavigatorTree(
            pages: [page("/about/", title: "About")],
            posts: [],
            fileGroups: [.styles: [FileRef(url: URL(fileURLWithPath: "/tmp/g.css"), group: .styles, name: "g.css")]]
        )
        #expect(sections.map(\.id) == [.pages, .styles])   // posts/components/metadata empty → omitted
    }

    @Test("page item uses title when present and route as fallback; target is the route")
    func pageItems() throws {
        let sections = buildNavigatorTree(
            pages: [page("/about/", title: "About"), page("/contact/", title: nil)],
            posts: [], fileGroups: [:])
        let pages = try #require(sections.first { $0.id == .pages })
        #expect(pages.items.map(\.title) == ["About", "/contact/"])
        #expect(pages.items.first?.target == .route("/about/"))
    }

    @Test("file item target carries the FileRef")
    func fileItems() throws {
        let ref = FileRef(url: URL(fileURLWithPath: "/tmp/Base.astro"), group: .components, name: "Base.astro")
        let sections = buildNavigatorTree(pages: [], posts: [], fileGroups: [.components: [ref]])
        let components = try #require(sections.first { $0.id == .components })
        let item = try #require(components.items.first)
        #expect(item.title == "Base.astro")
        #expect(item.target == .file(ref))
    }
}
