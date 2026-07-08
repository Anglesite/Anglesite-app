// Sources/AnglesiteCore/ProjectConventions.swift
import Foundation

/// Where a `Learned` field's current value came from.
public enum ConventionSource: Sendable, Codable, Equatable {
    case inferred(confidence: Double)
    case userOverride
}

/// One inferred-or-overridden fact about a project's conventions. Re-learning never overwrites
/// a `.userOverride` value — see `ProjectConventions.merging(overriddenFrom:)`.
public struct Learned<Value: Sendable & Codable & Equatable>: Sendable, Codable, Equatable {
    public var value: Value
    public var source: ConventionSource
    /// How many files this was inferred from, when known. `nil`/0 lets a future UI show a
    /// "low confidence" indicator instead of asserting a rule from too little evidence.
    public var sampleSize: Int?

    public init(value: Value, source: ConventionSource, sampleSize: Int? = nil) {
        self.value = value
        self.source = source
        self.sampleSize = sampleSize
    }

    public var isOverridden: Bool {
        if case .userOverride = source { return true }
        return false
    }
}

public enum HeadingCapitalization: String, Sendable, Codable, Equatable {
    case titleCase
    case sentenceCase
    case mixed
}

public enum SlugStyle: String, Sendable, Codable, Equatable {
    case kebabCase
    case snakeCase
    case mixed
}

public struct WritingConventions: Sendable, Codable, Equatable {
    public var headingCapitalization: Learned<HeadingCapitalization>
    public var toneDescriptors: Learned<[String]>
    public var brandTerms: Learned<[String]>

    public init(
        headingCapitalization: Learned<HeadingCapitalization>,
        toneDescriptors: Learned<[String]>,
        brandTerms: Learned<[String]>
    ) {
        self.headingCapitalization = headingCapitalization
        self.toneDescriptors = toneDescriptors
        self.brandTerms = brandTerms
    }
}

/// Read as ground truth from `src/content.config.ts` (Task 3) — not inferred, so no `Learned`
/// wrapper and never user-overridable. Maps collection name to its declared field names.
public struct FrontmatterConventions: Sendable, Codable, Equatable {
    public var collections: [String: [String]]

    public init(collections: [String: [String]]) {
        self.collections = collections
    }
}

public struct ComponentConventions: Sendable, Codable, Equatable {
    public var usageCounts: Learned<[String: Int]>

    public init(usageCounts: Learned<[String: Int]>) {
        self.usageCounts = usageCounts
    }
}

public struct ImageConventions: Sendable, Codable, Equatable {
    public var altTextAverageLength: Learned<Int>
    public var altTextEndsWithPunctuation: Learned<Bool>

    public init(altTextAverageLength: Learned<Int>, altTextEndsWithPunctuation: Learned<Bool>) {
        self.altTextAverageLength = altTextAverageLength
        self.altTextEndsWithPunctuation = altTextEndsWithPunctuation
    }
}

public struct NamingConventions: Sendable, Codable, Equatable {
    public var slugStyle: Learned<SlugStyle>

    public init(slugStyle: Learned<SlugStyle>) {
        self.slugStyle = slugStyle
    }
}

public struct SEOConventions: Sendable, Codable, Equatable {
    public var metaDescriptionAverageLength: Learned<Int>

    public init(metaDescriptionAverageLength: Learned<Int>) {
        self.metaDescriptionAverageLength = metaDescriptionAverageLength
    }
}

/// One site's learned/edited project conventions. See the design doc for the taxonomy and the
/// override-preserving merge invariant.
public struct ProjectConventions: Sendable, Codable, Equatable {
    public var writing: WritingConventions
    public var frontmatter: FrontmatterConventions
    public var components: ComponentConventions
    public var images: ImageConventions
    public var naming: NamingConventions
    public var seo: SEOConventions
    public var lastLearnedAt: Date?

    public init(
        writing: WritingConventions,
        frontmatter: FrontmatterConventions,
        components: ComponentConventions,
        images: ImageConventions,
        naming: NamingConventions,
        seo: SEOConventions,
        lastLearnedAt: Date?
    ) {
        self.writing = writing
        self.frontmatter = frontmatter
        self.components = components
        self.images = images
        self.naming = naming
        self.seo = seo
        self.lastLearnedAt = lastLearnedAt
    }

    /// A zero-confidence, empty starting point — what a brand-new site (or a site that hasn't
    /// been scanned yet) reports.
    public static let empty = ProjectConventions(
        writing: WritingConventions(
            headingCapitalization: Learned(value: .mixed, source: .inferred(confidence: 0), sampleSize: 0),
            toneDescriptors: Learned(value: [], source: .inferred(confidence: 0), sampleSize: 0),
            brandTerms: Learned(value: [], source: .inferred(confidence: 0), sampleSize: 0)
        ),
        frontmatter: FrontmatterConventions(collections: [:]),
        components: ComponentConventions(
            usageCounts: Learned(value: [:], source: .inferred(confidence: 0), sampleSize: 0)
        ),
        images: ImageConventions(
            altTextAverageLength: Learned(value: 0, source: .inferred(confidence: 0), sampleSize: 0),
            altTextEndsWithPunctuation: Learned(value: false, source: .inferred(confidence: 0), sampleSize: 0)
        ),
        naming: NamingConventions(
            slugStyle: Learned(value: .mixed, source: .inferred(confidence: 0), sampleSize: 0)
        ),
        seo: SEOConventions(
            metaDescriptionAverageLength: Learned(value: 0, source: .inferred(confidence: 0), sampleSize: 0)
        ),
        lastLearnedAt: nil
    )
}

/// Every field a user can override from the Style Guide inspector (Task 10). Frontmatter
/// (ground truth) and component usage counts (a count, not a preference) are intentionally
/// excluded.
public enum OverridableField: String, Sendable, Codable, CaseIterable {
    case headingCapitalization
    case toneDescriptors
    case brandTerms
    case altTextAverageLength
    case altTextEndsWithPunctuation
    case slugStyle
    case metaDescriptionAverageLength
}

/// A typed value for one `OverridableField`. The case identifies the field; the payload is
/// already the right type for it, so callers can't set a `String` onto an `Int` field.
public enum OverrideValue: Sendable, Equatable {
    case headingCapitalization(HeadingCapitalization)
    case toneDescriptors([String])
    case brandTerms([String])
    case altTextAverageLength(Int)
    case altTextEndsWithPunctuation(Bool)
    case slugStyle(SlugStyle)
    case metaDescriptionAverageLength(Int)
}

extension ProjectConventions {
    /// Sets the matching field's value and flips its `source` to `.userOverride`.
    public mutating func apply(_ value: OverrideValue) {
        switch value {
        case .headingCapitalization(let v):
            writing.headingCapitalization = Learned(value: v, source: .userOverride)
        case .toneDescriptors(let v):
            writing.toneDescriptors = Learned(value: v, source: .userOverride)
        case .brandTerms(let v):
            writing.brandTerms = Learned(value: v, source: .userOverride)
        case .altTextAverageLength(let v):
            images.altTextAverageLength = Learned(value: v, source: .userOverride)
        case .altTextEndsWithPunctuation(let v):
            images.altTextEndsWithPunctuation = Learned(value: v, source: .userOverride)
        case .slugStyle(let v):
            naming.slugStyle = Learned(value: v, source: .userOverride)
        case .metaDescriptionAverageLength(let v):
            seo.metaDescriptionAverageLength = Learned(value: v, source: .userOverride)
        }
    }

    /// Reverts one field's `source` back to `.inferred`, keeping its current value in place until
    /// the next rebuild recomputes it fresh.
    public mutating func clearOverride(_ field: OverridableField) {
        switch field {
        case .headingCapitalization:
            writing.headingCapitalization.source = .inferred(confidence: 0)
        case .toneDescriptors:
            writing.toneDescriptors.source = .inferred(confidence: 0)
        case .brandTerms:
            writing.brandTerms.source = .inferred(confidence: 0)
        case .altTextAverageLength:
            images.altTextAverageLength.source = .inferred(confidence: 0)
        case .altTextEndsWithPunctuation:
            images.altTextEndsWithPunctuation.source = .inferred(confidence: 0)
        case .slugStyle:
            naming.slugStyle.source = .inferred(confidence: 0)
        case .metaDescriptionAverageLength:
            seo.metaDescriptionAverageLength.source = .inferred(confidence: 0)
        }
    }

    /// `self` is a freshly-recomputed rebuild result. Returns a copy where every field the user
    /// had overridden in `previous` is preserved verbatim; every other field keeps `self`'s fresh
    /// value. This is the invariant that makes re-learning safe to run automatically in the
    /// background without clobbering user edits.
    public func merging(overriddenFrom previous: ProjectConventions) -> ProjectConventions {
        var merged = self
        if previous.writing.headingCapitalization.isOverridden {
            merged.writing.headingCapitalization = previous.writing.headingCapitalization
        }
        if previous.writing.toneDescriptors.isOverridden {
            merged.writing.toneDescriptors = previous.writing.toneDescriptors
        }
        if previous.writing.brandTerms.isOverridden {
            merged.writing.brandTerms = previous.writing.brandTerms
        }
        if previous.images.altTextAverageLength.isOverridden {
            merged.images.altTextAverageLength = previous.images.altTextAverageLength
        }
        if previous.images.altTextEndsWithPunctuation.isOverridden {
            merged.images.altTextEndsWithPunctuation = previous.images.altTextEndsWithPunctuation
        }
        if previous.naming.slugStyle.isOverridden {
            merged.naming.slugStyle = previous.naming.slugStyle
        }
        if previous.seo.metaDescriptionAverageLength.isOverridden {
            merged.seo.metaDescriptionAverageLength = previous.seo.metaDescriptionAverageLength
        }
        return merged
    }
}
