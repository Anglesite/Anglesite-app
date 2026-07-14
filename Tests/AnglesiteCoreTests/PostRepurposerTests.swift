import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct PostRepurposerTests {
    private var post: PostSource {
        PostSource(collection: "posts", slug: "coast-trip", title: "Coast Trip",
                   description: "A weekend on the coast", tags: ["travel"],
                   body: "We drove out early and the fog lifted by ten.",
                   filePath: "src/content/posts/coast-trip.mdoc")
    }

    @Test func factoryMatchesToolchain() {
        let repurposer = PostRepurposerFactory.makeDefault()
        #if compiler(>=6.4) && canImport(FoundationModels)
        #expect(repurposer != nil)
        #else
        #expect(repurposer == nil)
        #endif
    }

    @Test func promptCarriesLimitURLPolicyAndBody() {
        let spec = RepurposePlatformSpecs.all.first { $0.platform == "X" }!
        let p = RepurposePrompt.build(post: post, postURL: "https://e.com/posts/coast-trip/",
                                      spec: spec, preamble: "Match this site's voice:\nwarm.")
        #expect(p.contains("280"))
        #expect(p.contains("https://e.com/posts/coast-trip/"))
        #expect(p.contains("fog lifted"))
        #expect(p.contains("warm"))
        let insta = RepurposePlatformSpecs.all.first { $0.platform == "Instagram" }!
        let ip = RepurposePrompt.build(post: post, postURL: "https://e.com/posts/coast-trip/",
                                       spec: insta, preamble: nil)
        #expect(ip.contains("Do not include any URL"))
    }

    @Test func replyRendersVariantsAndFailures() {
        let variants = [
            PlatformPostVariant(platform: "X", text: "Fog lifted by ten. https://e.com/p/", failure: nil),
            PlatformPostVariant(platform: "Bluesky", text: nil, failure: "Couldn't fit Bluesky's 300-character limit."),
        ]
        let text = RepurposeReply.text(postTitle: "Coast Trip", variants: variants)
        #expect(text.contains("Coast Trip"))
        #expect(text.contains("X:"))
        #expect(text.contains("Fog lifted"))
        #expect(text.contains("300-character"))
        #expect(text.contains("saveSyndication")) // instructs the follow-up write-back
    }

    @Test func missingDomainWarningNamesTheProblem() {
        #expect(RepurposeReply.missingDomainWarning.contains("example.com"))
        #expect(RepurposeReply.missingDomainWarning.contains("domain"))
    }
}
