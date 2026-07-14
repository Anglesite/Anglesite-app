import Foundation

public struct SocialPillar: Sendable, Equatable {
    public let name: String
    public let detail: String
    public init(name: String, detail: String) {
        self.name = name
        self.detail = detail
    }
}

public struct SocialCalendarEntry: Sendable, Equatable {
    public let day: String
    public let platform: String
    public let pillar: String
    public let idea: String
    public init(day: String, platform: String, pillar: String, idea: String) {
        self.day = day
        self.platform = platform
        self.pillar = pillar
        self.idea = idea
    }
}

public struct SocialCalendarWeek: Sendable, Equatable {
    public let startDate: Date
    public let entries: [SocialCalendarEntry]
    public init(startDate: Date, entries: [SocialCalendarEntry]) {
        self.startDate = startDate
        self.entries = entries
    }
}

/// A generated social plan: FM writes the content, deterministic Swift owns the structure and
/// the file format (spec §5.2). `bios` is keyed by platform name; a missing key means that
/// bio couldn't be generated within its limit.
public struct SocialMediaPlan: Sendable, Equatable {
    public let businessType: String?
    public let platforms: [SocialPlatformProfile]
    public let bios: [String: String]
    public let pillars: [SocialPillar]
    public let weeks: [SocialCalendarWeek]

    public init(businessType: String?, platforms: [SocialPlatformProfile], bios: [String: String],
                pillars: [SocialPillar], weeks: [SocialCalendarWeek]) {
        self.businessType = businessType
        self.platforms = platforms
        self.bios = bios
        self.pillars = pillars
        self.weeks = weeks
    }
}
