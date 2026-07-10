import Foundation

/// Deterministic platform recommendation by business type — ported from the social-media
/// skill's business-type→platform table (v1: a representative subset; enriching from the SMB
/// guides is a tracked follow-up). Cadence is posts per week.
public struct SocialPlatformProfile: Sendable, Equatable {
    public let platform: String
    public let bioCharLimit: Int
    public let postsPerWeek: Int
    public let note: String

    public init(platform: String, bioCharLimit: Int, postsPerWeek: Int, note: String) {
        self.platform = platform
        self.bioCharLimit = bioCharLimit
        self.postsPerWeek = postsPerWeek
        self.note = note
    }
}

public enum SocialPlatformCatalog {
    static let instagram = SocialPlatformProfile(platform: "Instagram", bioCharLimit: 150, postsPerWeek: 4, note: "visual-first; photos and reels")
    static let facebook = SocialPlatformProfile(platform: "Facebook", bioCharLimit: 255, postsPerWeek: 3, note: "community updates and events")
    static let googleBusiness = SocialPlatformProfile(platform: "Google Business", bioCharLimit: 750, postsPerWeek: 2, note: "posts show in local search")
    static let nextdoor = SocialPlatformProfile(platform: "Nextdoor", bioCharLimit: 500, postsPerWeek: 1, note: "neighborhood word of mouth")
    static let bluesky = SocialPlatformProfile(platform: "Bluesky", bioCharLimit: 256, postsPerWeek: 3, note: "conversational, link-friendly")

    public static func recommended(businessType: String?) -> [SocialPlatformProfile] {
        switch businessType?.lowercased() {
        case "restaurant", "cafe", "bakery", "food-truck":
            return [instagram, facebook, googleBusiness]
        case "trades", "landscaping", "cleaning", "handyman", "plumber", "electrician":
            return [facebook, nextdoor, googleBusiness]
        case "web-artist", "photographer", "designer", "artist", "studio":
            return [instagram, bluesky]
        case "retail", "boutique", "shop":
            return [instagram, facebook, googleBusiness]
        case "salon", "barber", "spa", "wellness":
            return [instagram, googleBusiness, facebook]
        default:
            return [facebook, instagram, googleBusiness]
        }
    }
}
