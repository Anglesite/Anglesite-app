import Foundation

/// Per-platform constraints for repurposed posts — the repurpose skill's table as Swift data.
/// Char limits are enforced in Swift (spec §5.3), never trusted to the model.
public struct PlatformPostSpec: Sendable, Equatable {
    public let platform: String
    public let charLimit: Int
    /// Whether the post should end with the canonical post URL (Instagram strips links).
    public let includesURL: Bool
    public let allowsHashtags: Bool
    public let styleHint: String

    public init(platform: String, charLimit: Int, includesURL: Bool, allowsHashtags: Bool, styleHint: String) {
        self.platform = platform
        self.charLimit = charLimit
        self.includesURL = includesURL
        self.allowsHashtags = allowsHashtags
        self.styleHint = styleHint
    }
}

public enum RepurposePlatformSpecs {
    public static let all: [PlatformPostSpec] = [
        PlatformPostSpec(platform: "Instagram", charLimit: 2200, includesURL: false, allowsHashtags: true,
                         styleHint: "engaging caption; mention 'link in bio'; end with a handful of relevant hashtags"),
        PlatformPostSpec(platform: "Facebook", charLimit: 500, includesURL: true, allowsHashtags: false,
                         styleHint: "conversational, one short paragraph"),
        PlatformPostSpec(platform: "Google Business", charLimit: 1500, includesURL: true, allowsHashtags: false,
                         styleHint: "informative and action-oriented for local searchers"),
        PlatformPostSpec(platform: "Nextdoor", charLimit: 800, includesURL: true, allowsHashtags: false,
                         styleHint: "neighborly, local framing"),
        PlatformPostSpec(platform: "X", charLimit: 280, includesURL: true, allowsHashtags: true,
                         styleHint: "punchy single post"),
        PlatformPostSpec(platform: "Bluesky", charLimit: 300, includesURL: true, allowsHashtags: true,
                         styleHint: "punchy single post"),
    ]

    public static func fits(_ text: String, spec: PlatformPostSpec) -> Bool {
        text.count <= spec.charLimit
    }
}
