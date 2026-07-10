import Foundation

public enum ConversationStage: Int, Sendable, Equatable, CaseIterable {
    case intent, mood, brandAnchor, axisConfirmation, done
}

/// A fixed nudge applied to one axis when the user's free text names a direction rather than a
/// slider value (e.g. "make it warmer"). Each hint moves its axis by a flat 0.15, clamped to [0,1].
public enum DesignAdjectiveHint: String, Sendable, CaseIterable {
    case warmer, cooler, denser, airier, moreAuthoritative, morePlayful, moreClassic, moreContemporary, bolder, subtler

    var keyPath: WritableKeyPath<DesignAxes, Double> {
        switch self {
        case .warmer, .cooler: return \.temperature
        case .denser, .airier: return \.weight
        case .moreAuthoritative, .morePlayful: return \.register
        case .moreClassic, .moreContemporary: return \.time
        case .bolder, .subtler: return \.voice
        }
    }

    var delta: Double {
        switch self {
        case .warmer, .denser, .moreAuthoritative, .moreContemporary, .bolder: return 0.15
        case .cooler, .airier, .morePlayful, .moreClassic, .subtler: return -0.15
        }
    }
}

public struct DesignInterviewDraft: Sendable, Equatable {
    public var stage: ConversationStage
    public var businessType: String
    public var axes: DesignAxes
    public var brandColorHex: String?
    public var freeTextNotes: [String]

    public init(businessType: String) {
        self.stage = .intent
        self.businessType = businessType
        self.axes = DesignAxesCatalog.defaults(forBusinessType: businessType)
        self.brandColorHex = nil
        self.freeTextNotes = []
    }

    public mutating func advance() {
        guard let next = ConversationStage(rawValue: stage.rawValue + 1) else { return }
        stage = next
    }

    public mutating func applyAdjectiveHint(_ hint: DesignAdjectiveHint) {
        axes = DesignAxesCatalog.adjusted(axes, by: [hint.keyPath: hint.delta])
    }
}
