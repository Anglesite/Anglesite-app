import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("ContentMatchEntity")
    struct ContentMatchEntityTests {
        @Test("projects each entity kind to a uniform shape")
        func projectsKinds() {
            let pm = ContentMatchEntity(PageEntity(AppIntentsTests.gPage(route: "/about", title: "About")))
            #expect(pm.kind == .page)
            #expect(pm.title == "About")
            #expect(pm.path == "/about")
            #expect(pm.id == "\(AppIntentsTests.aSite):page:/about")

            let som = ContentMatchEntity(PostEntity(AppIntentsTests.gPost(slug: "hello-world", title: "Hello World", collection: "blog")))
            #expect(som.kind == .post)
            #expect(som.path == "hello-world")

            let im = ContentMatchEntity(ImageEntity(AppIntentsTests.gImage(relativePath: "public/images/hero.jpg")))
            #expect(im.kind == .image)
            #expect(im.path == "public/images/hero.jpg")
        }

        @Test("query resolves a mixed id list back to the right kinds, in input order")
        func queryResolvesMixedIDs() async throws {
            let graph = SiteContentGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage(route: "/about", title: "About")],
                posts: [AppIntentsTests.gPost(slug: "hello-world")],
                images: [AppIntentsTests.gImage(relativePath: "public/images/hero.jpg")]
            )
            let ids = [
                "\(AppIntentsTests.aSite):image:public/images/hero.jpg",
                "\(AppIntentsTests.aSite):page:/about",
                "\(AppIntentsTests.aSite):post:hello-world",
            ]
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let r = try await ContentMatchEntityQuery().entities(for: ids)
                #expect(r.map(\.id) == ids)               // input order preserved
                #expect(r.map(\.kind) == [.image, .page, .post])
            }
        }
    }
}
