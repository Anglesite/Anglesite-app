import AppIntents
import AnglesiteCore

/// The typed content kinds a user can filter by (the `.collection`-stored built-ins from
/// `ContentTypeRegistry`). An `AppEnum` so it appears as a typed picker in Shortcuts and in the
/// auto-derived MCP schema. `rawValue` is the registry id; kept in sync by a drift-guard test
/// (`ContentTypeAppEnumTests`) — adding a built-in collection type fails that test until a case
/// is added here. `businessProfile` (page singleton) is intentionally absent (#351 scope).
public enum ContentTypeAppEnum: String, AppEnum, Sendable, CaseIterable {
    case note, article, photo, album, bookmark, reply, like
    case announcement, event, review

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Content Type" }

    public static var caseDisplayRepresentations: [ContentTypeAppEnum: DisplayRepresentation] {
        [
            .note: "Note", .article: "Article", .photo: "Photo", .album: "Album",
            .bookmark: "Bookmark", .reply: "Reply", .like: "Like",
            .announcement: "Announcement", .event: "Event", .review: "Review",
        ]
    }

    /// The Astro content collection backing this type (e.g. `.event` → "events"), via the registry.
    public var collection: String? {
        ContentTypeRegistry.default.descriptor(id: rawValue)?.collection
    }
}
