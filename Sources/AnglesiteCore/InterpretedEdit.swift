import Foundation

/// The kind of change a natural-language instruction resolves to. Plain (no FoundationModels
/// dependency) so the op-mapping compiles + tests on the CI toolchain.
public enum InterpretedEditKind: String, Sendable, Equatable {
    case text, attribute, style
}

/// A model-independent representation of an interpreted edit. The FM-backed interpreter (gated
/// behind `#if compiler(>=6.4)`) produces this; the op-mapping below is pure and CI-tested.
public struct InterpretedEdit: Sendable, Equatable {
    public let kind: InterpretedEditKind
    public let newText: String?
    public let attributeName: String?
    public let attributeValue: String?
    public let styleProperty: String?
    public let styleValue: String?
    /// One-line human phrasing of the change, for the confirmation dialog.
    public let summary: String

    public init(kind: InterpretedEditKind, newText: String?, attributeName: String?, attributeValue: String?,
                styleProperty: String?, styleValue: String?, summary: String) {
        self.kind = kind; self.newText = newText
        self.attributeName = attributeName; self.attributeValue = attributeValue
        self.styleProperty = styleProperty; self.styleValue = styleValue; self.summary = summary
    }

    /// Map to the concrete plugin op + value, or nil if the kind's required payload is missing.
    public func resolveOp() -> ResolvedEditOp? {
        switch kind {
        case .text:
            guard let t = newText, !t.isEmpty else { return nil }
            return ResolvedEditOp(op: "replace-text", value: .string(t))
        case .attribute:
            guard let n = attributeName, !n.isEmpty, let v = attributeValue else { return nil }
            return ResolvedEditOp(op: "replace-attr", value: .object(["name": .string(n), "value": .string(v)]))
        case .style:
            guard let p = styleProperty, !p.isEmpty, let v = styleValue, !v.isEmpty else { return nil }
            return ResolvedEditOp(op: "edit-style", value: .object(["property": .string(p), "value": .string(v)]))
        }
    }
}

public struct ResolvedEditOp: Sendable, Equatable {
    public let op: String
    public let value: JSONValue
    public init(op: String, value: JSONValue) { self.op = op; self.value = value }
}

/// Context about the onscreen element the instruction targets.
public struct InterpretedElementContext: Sendable, Equatable {
    public let tag: String
    public let currentText: String?
    public let pagePath: String
    public let displayName: String
    public init(tag: String, currentText: String?, pagePath: String, displayName: String) {
        self.tag = tag; self.currentText = currentText; self.pagePath = pagePath; self.displayName = displayName
    }
}

/// Seam between the intent and the on-device model. The live implementation is FM-backed and
/// `#if compiler(>=6.4)`-gated; tests inject a fake returning a canned `InterpretedEdit`.
public protocol EditInterpreting: Sendable {
    func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit
}

/// Thrown when on-device interpretation can't run (Apple Intelligence unavailable, etc.).
public enum EditInterpretationError: Error, Sendable, Equatable {
    case unavailable(String)
}
