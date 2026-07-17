import Foundation

/// Groups a component's style rules by their `@media` condition (design spec §4.3: "Media
/// queries as collapsible sections"), preserving the order each distinct condition first
/// appears in the source. Pure/testable — `ComponentEditorView`'s Styles panel renders one
/// collapsible section per group, reusing the existing per-rule editing UI inside.
public enum ComponentStyleGrouping {
    /// One rule plus its original index in the model's flat `styles` array — callers need the
    /// index to re-derive a fresh span via `ComponentEditorModel.ruleSpan(atIndex:)` after a
    /// prior write in the same gesture may have shifted byte offsets (same reason the previous
    /// flat rendering carried `ruleIndex` alongside each rule).
    public struct IndexedRule: Sendable, Equatable {
        public let index: Int
        public let rule: ComponentModel.StyleRule
    }

    /// One media-scoped (or unscoped, `media == nil`) run of rules.
    public struct Group: Sendable, Equatable {
        public let media: String?
        public let rules: [IndexedRule]
    }

    /// Groups rules sharing the same `media` value into one `Group` each, in first-appearance
    /// order — NOT sorted alphabetically, so a component whose source interleaves base and
    /// media-scoped rules still reads top-to-bottom the way it's written. A `media` value
    /// re-encountered later in the array joins its existing group rather than starting a new one.
    public static func groups(from styles: [ComponentModel.StyleRule]) -> [Group] {
        var order: [String] = []
        var byKey: [String: [IndexedRule]] = [:]
        for (index, rule) in styles.enumerated() {
            let key = rule.media ?? ""
            if byKey[key] == nil {
                byKey[key] = []
                order.append(key)
            }
            byKey[key]?.append(IndexedRule(index: index, rule: rule))
        }
        return order.map { key in
            Group(media: key.isEmpty ? nil : key, rules: byKey[key] ?? [])
        }
    }

    /// Strips a redundant leading "@media" a user may have typed into the Styles panel's "Add
    /// rule" form condition field (case-insensitive, tolerates surrounding whitespace) — the
    /// field only asks for the condition itself (e.g. `"(min-width: 768px)"`), but typing the
    /// literal `"@media (min-width: 768px)"` is a natural mistake given the field sits right
    /// next to text that says "@media". Without this, the rendered section header
    /// (`"@media \(condition)"`) would double up as `"@media @media (min-width: 768px)"`
    /// (PR #795 review).
    public static func normalizeMediaCondition(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("@media") else { return trimmed }
        return String(trimmed.dropFirst("@media".count)).trimmingCharacters(in: .whitespaces)
    }
}
