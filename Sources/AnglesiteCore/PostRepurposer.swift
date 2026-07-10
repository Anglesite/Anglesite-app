import Foundation

/// One platform's repurposed post: `text` on success, `failure` (user-facing) when the model
/// couldn't satisfy the platform's hard limit after a retry — never silently truncated.
public struct PlatformPostVariant: Sendable, Equatable {
    public let platform: String
    public let text: String?
    public let failure: String?

    public init(platform: String, text: String?, failure: String?) {
        self.platform = platform
        self.text = text
        self.failure = failure
    }
}

/// Pure prompt builder for one platform variant — non-gated for CI tests.
public enum RepurposePrompt {
    public static func build(post: PostSource, postURL: String, spec: PlatformPostSpec,
                             preamble: String?) -> String {
        var rules: [String] = []
        rules.append("Hard limit: \(spec.charLimit) characters total — shorter is better.")
        rules.append(spec.includesURL
            ? "End with the post's link: \(postURL)"
            : "Do not include any URL (\(spec.platform) strips links); say 'link in bio' instead.")
        rules.append(spec.allowsHashtags
            ? "A few relevant hashtags are welcome."
            : "No hashtags.")
        rules.append("Style: \(spec.styleHint).")
        let sections = [
            preamble,
            """
            Write a \(spec.platform) post that shares this blog post with the owner's followers.
            \(rules.joined(separator: "\n"))

            Blog post title: \(post.title)
            \(post.description.map { "Summary: \($0)" } ?? "")
            Blog post text:
            \(post.body)
            """,
        ]
        return sections.compactMap { $0 }.joined(separator: "\n\n")
    }
}

public protocol PostRepurposing: Sendable {
    func variants(post: PostSource, postURL: String, specs: [PlatformPostSpec], preamble: String?,
                  siteID: String, siteDirectory: URL) async -> [PlatformPostVariant]
}

public enum PostRepurposerFactory {
    public static func makeDefault() -> (any PostRepurposing)? {
        #if compiler(>=6.4)
        return FoundationModelPostRepurposer()
        #else
        return nil
        #endif
    }
}

#if compiler(>=6.4)
import FoundationModels

public struct FoundationModelPostRepurposer: PostRepurposing {
    public init() {}

    public func variants(post: PostSource, postURL: String, specs: [PlatformPostSpec], preamble: String?,
                         siteID: String, siteDirectory: URL) async -> [PlatformPostVariant] {
        guard let assistant = ContentAssistantFactory.make(tier: .privateCloudCompute) else {
            return specs.map { PlatformPostVariant(
                platform: $0.platform, text: nil,
                failure: ContentHelpDialogs.assistantUnavailable(feature: "Repurposing")) }
        }
        let context = AssistantContext(siteID: siteID, siteDirectory: siteDirectory)
        var out: [PlatformPostVariant] = []
        for spec in specs {
            out.append(await variant(for: spec, post: post, postURL: postURL, preamble: preamble,
                                     assistant: assistant, context: context))
        }
        return out
    }

    /// Spec §5.3: validate in Swift → one retry with the measured overshoot → fail with a message.
    private func variant(for spec: PlatformPostSpec, post: PostSource, postURL: String,
                         preamble: String?, assistant: any ContentAssistant,
                         context: AssistantContext) async -> PlatformPostVariant {
        let prompt = RepurposePrompt.build(post: post, postURL: postURL, spec: spec, preamble: preamble)
        guard let first = try? await assistant.generateStructured(
            prompt: prompt, context: context, resultType: GeneratedPlatformPost.self) else {
            return PlatformPostVariant(platform: spec.platform, text: nil,
                                       failure: "Couldn't generate a \(spec.platform) post.")
        }
        if RepurposePlatformSpecs.fits(first.text, spec: spec) {
            return PlatformPostVariant(platform: spec.platform, text: first.text, failure: nil)
        }
        let retryPrompt = prompt + "\n\nYour previous attempt was \(first.text.count) characters — over the \(spec.charLimit)-character limit. Rewrite it well under \(spec.charLimit) characters."
        if let second = try? await assistant.generateStructured(
            prompt: retryPrompt, context: context, resultType: GeneratedPlatformPost.self),
           RepurposePlatformSpecs.fits(second.text, spec: spec) {
            return PlatformPostVariant(platform: spec.platform, text: second.text, failure: nil)
        }
        return PlatformPostVariant(platform: spec.platform, text: nil,
                                   failure: "Couldn't fit \(spec.platform)'s \(spec.charLimit)-character limit.")
    }
}
#endif
