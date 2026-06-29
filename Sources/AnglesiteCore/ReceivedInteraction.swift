// Sources/AnglesiteCore/ReceivedInteraction.swift
import Foundation

/// Schema for a received interaction snapshotted from the Worker's inbox store into `Source/` git.
///
/// This is the data contract between the Worker (D1 → JSON serialization) and the Astro template
/// (glob loader → render). One file per interaction at `Source/data/interactions/{id}.json`.
/// See `docs/specs/2026-06-29-c3-received-interaction-canonicality.md` for the full design.
///
/// **Sanitisation contract:** `id` is validated at construction time — only `[A-Za-z0-9_-]+`
/// is accepted — to prevent path-traversal through `gitPath`. `content` is stored as-is from
/// the Worker; the Astro template must sanitise it before rendering as HTML (e.g. use
/// `set:text` not `set:html`, or run through a sanitiser first).
public struct ReceivedInteraction: Codable, Sendable, Equatable, Identifiable {
    /// Protocol source of the interaction.
    public enum ProtocolType: String, Codable, Sendable, Equatable {
        case webmention
        case activitypub
        case micropub
    }

    /// What kind of interaction this represents.
    public enum InteractionType: String, Codable, Sendable, Equatable {
        case reply
        case like
        case repost
        case bookmark
        case mention

        /// Whether this interaction renders as a threaded comment.
        public var isComment: Bool { self == .reply }
        /// Whether this interaction renders as a facepile avatar.
        public var isFacepile: Bool { self == .like || self == .repost }
    }

    /// Verification state of the interaction.
    public enum VerificationStatus: String, Codable, Sendable, Equatable {
        case verified
        case pending
        case failed
    }

    /// Frozen point-in-time snapshot of the sender's identity at verification time.
    ///
    /// This is not live-updated — if the sender changes their name/photo, the old values
    /// persist in the snapshot. This is standard IndieWeb practice.
    public struct Author: Codable, Sendable, Equatable {
        public let name: String?
        public let url: URL?
        public let photo: URL?

        public init(name: String?, url: URL?, photo: URL?) {
            self.name = name
            self.url = url
            self.photo = photo
        }
    }

    /// Stable, unique ID assigned by the Worker (e.g. `wm-{hash}`, `ap-{hash}`).
    public let id: String
    /// Protocol source — webmention, activitypub, or micropub.
    public let type: ProtocolType
    /// The URL that sent the interaction.
    public let source: URL
    /// The URL on this site that received it.
    public let target: URL
    /// What kind of interaction this represents.
    public let interactionType: InteractionType
    /// Frozen point-in-time snapshot of the sender's identity (optional).
    public let author: Author?
    /// Text/HTML content of the interaction (optional, may be truncated to ~500 chars).
    /// Stored as-is from the Worker — callers must sanitise before rendering as raw HTML.
    public let content: String?
    /// When the source published the interaction (ISO 8601).
    public let published: Date
    /// When the Worker verified the interaction (ISO 8601).
    public let verified: Date
    /// Current verification state of the interaction.
    public let verificationStatus: VerificationStatus

    /// The relative path within `Source/` where this interaction is stored in git.
    ///
    /// For example: `"data/interactions/wm-abc123.json"`
    public var gitPath: String { "data/interactions/\(id).json" }

    public enum ValidationError: Error, Sendable {
        case invalidID(String)
    }

    public init(
        id: String,
        type: ProtocolType,
        source: URL,
        target: URL,
        interactionType: InteractionType,
        author: Author?,
        content: String?,
        published: Date,
        verified: Date,
        verificationStatus: VerificationStatus
    ) throws {
        guard id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ValidationError.invalidID(id)
        }
        self.id = id
        self.type = type
        self.source = source
        self.target = target
        self.interactionType = interactionType
        self.author = author
        self.content = content
        self.published = published
        self.verified = verified
        self.verificationStatus = verificationStatus
    }
}
