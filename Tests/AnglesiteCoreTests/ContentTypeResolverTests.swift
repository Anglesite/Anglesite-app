import Testing
@testable import AnglesiteCore

@Suite("ContentTypeResolver")
struct ContentTypeResolverTests {
    @Test("collection entry resolves by directory")
    func collection() {
        #expect(ContentTypeResolver.descriptor(forRelativePath: "src/content/notes/hello.md")?.id == "note")
        #expect(ContentTypeResolver.descriptor(forRelativePath: "src/content/events/launch.md")?.id == "event")
    }

    @Test("businessProfile resolves by its singleton page path")
    func businessProfile() {
        #expect(ContentTypeResolver.descriptor(forRelativePath: "src/pages/about.md")?.id == "businessProfile")
    }

    @Test("leading ./ and absolute-ish prefixes are tolerated")
    func normalization() {
        #expect(ContentTypeResolver.descriptor(forRelativePath: "./src/content/articles/x.md")?.id == "article")
    }

    @Test("unrelated files resolve to nil (text fallback)")
    func none() {
        #expect(ContentTypeResolver.descriptor(forRelativePath: "src/pages/index.astro") == nil)
        #expect(ContentTypeResolver.descriptor(forRelativePath: "src/styles/global.css") == nil)
    }
}
