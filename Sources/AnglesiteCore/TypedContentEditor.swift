// Sources/AnglesiteCore/TypedContentEditor.swift
import Foundation

/// Bridges a content file to the typed, per-field values a form editor binds to, and back.
///
/// One `markdown` field per type (the `body`) maps to the document body; every other field maps to
/// a frontmatter key. `write` applies only fields whose value actually changed, so
/// `FrontmatterDocument`'s verbatim preservation keeps untouched keys and the body intact. Pure,
/// no I/O.
public enum TypedContentEditor {
    public enum FieldValue: Equatable, Sendable {
        case text(String)
        case flag(Bool)
        case date(Date?)
        case number(Double?)
        case list([String])
    }

    public struct Values: Equatable, Sendable {
        private var dict: [String: FieldValue]
        public init(_ dict: [String: FieldValue] = [:]) { self.dict = dict }
        public subscript(_ name: String) -> FieldValue? {
            get { dict[name] }
            set { dict[name] = newValue }
        }
    }

    public static func defaultValue(for kind: ContentTypeField.Kind) -> FieldValue {
        switch kind {
        case .string, .text, .markdown, .url, .image: return .text("")
        case .bool: return .flag(false)
        case .date, .datetime: return .date(nil)
        case .number: return .number(nil)
        case .stringArray, .imageArray: return .list([])
        }
    }

    public static func read(_ contents: String, descriptor: ContentTypeDescriptor) -> Values {
        read(from: FrontmatterDocument.parse(contents), descriptor: descriptor)
    }

    /// Reads field values from an already-parsed document. `write` reuses this to derive the current
    /// values without re-parsing `contents` a second time.
    private static func read(from doc: FrontmatterDocument, descriptor: ContentTypeDescriptor) -> Values {
        var out = Values()
        for field in descriptor.fields {
            if field.kind == .markdown {
                out[field.name] = .text(doc.body)
                continue
            }
            guard let raw = doc.value(for: field.name) else {
                out[field.name] = defaultValue(for: field.kind)
                continue
            }
            out[field.name] = decode(raw, kind: field.kind)
        }
        return out
    }

    public static func write(_ values: Values, into contents: String, descriptor: ContentTypeDescriptor) -> String {
        var doc = FrontmatterDocument.parse(contents)
        // Derive `current` from the already-parsed `doc` (no second parse). Comparison stays at the
        // decoded `FieldValue` level on purpose: it preserves an unchanged field verbatim even when
        // its on-disk form isn't canonical (e.g. a date-only or no-fractional-seconds `publishDate`),
        // which a re-encoded string comparison would reformat.
        let current = read(from: doc, descriptor: descriptor)
        for field in descriptor.fields {
            guard let newValue = values[field.name], newValue != current[field.name] else { continue }
            if field.kind == .markdown {
                if case .text(let body) = newValue { doc.body = body }
                continue
            }
            if let encoded = encode(newValue, kind: field.kind) { doc.set(encoded, for: field.name) }
        }
        return doc.serialized()
    }

    // MARK: Decode (frontmatter → field value)

    private static func decode(_ value: FrontmatterValue, kind: ContentTypeField.Kind) -> FieldValue {
        switch kind {
        case .string, .text, .url, .image, .markdown:
            if case .string(let s) = value { return .text(s) }
            return .text("")
        case .bool:
            if case .bool(let b) = value { return .flag(b) }
            return .flag(false)
        case .date, .datetime:
            if case .string(let s) = value { return .date(parseDate(s)) }
            return .date(nil)
        case .number:
            if case .string(let s) = value { return .number(Double(s)) }
            return .number(nil)
        case .stringArray, .imageArray:
            if case .array(let a) = value { return .list(a) }
            return .list([])
        }
    }

    // MARK: Encode (field value → frontmatter)

    private static func encode(_ value: FieldValue, kind: ContentTypeField.Kind) -> FrontmatterValue? {
        switch value {
        case .text(let s): return .string(s)
        case .flag(let b): return .bool(b)
        case .date(let d): return .string(d.map { format($0, kind: kind) } ?? "")
        case .number(let n): return .string(n.map { formatNumber($0) } ?? "")
        case .list(let a): return .array(a)
        }
    }

    // MARK: Date/number formatting (mirror ContentScaffold)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func format(_ date: Date, kind: ContentTypeField.Kind) -> String {
        let full = iso.string(from: date)
        return kind == .date ? String(full.prefix(10)) : full
    }

    private static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        // date-only (yyyy-MM-dd) → midnight UTC
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .iso8601)
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)
    }

    private static func formatNumber(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }
}
