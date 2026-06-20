#if compiler(>=6.4)
import Foundation
import FoundationModels

/// Structured output the on-device model fills in guided generation. Mapped to the
/// FM-independent `InterpretedEdit` so op-routing stays CI-testable without the live model.
@Generable
public struct GeneratedInterpretedEdit: Equatable, Sendable {
    @Guide(description: "The kind of change: text (replace the element's visible text), attribute (set an HTML attribute like alt or href), or style (a CSS property like color or font-size).")
    public var kind: InterpretedEditKindGen

    @Guide(description: "For a text edit: the full new visible text. Empty otherwise.")
    public var newText: String

    @Guide(description: "For an attribute edit: the attribute name (e.g. alt, href). Empty otherwise.")
    public var attributeName: String

    @Guide(description: "For an attribute edit: the new attribute value. Empty otherwise.")
    public var attributeValue: String

    @Guide(description: "For a style edit: the CSS property (e.g. color, font-size). Empty otherwise.")
    public var styleProperty: String

    @Guide(description: "For a style edit: the CSS value (e.g. teal, 2rem). Empty otherwise.")
    public var styleValue: String

    @Guide(description: "One short sentence describing the change, shown to the user before they confirm.")
    public var summary: String
}

/// `@Generable` mirror of `InterpretedEditKind`. Kept separate so the FM dependency doesn't
/// bleed into the plain model type used by CI-testable op-routing.
@Generable
public enum InterpretedEditKindGen: String, Equatable, Sendable {
    case text, attribute, style
}

/// FM-backed `EditInterpreting`. The `generate` closure is injected so unit tests can supply a
/// canned `GeneratedInterpretedEdit` without the live model; the production initializer wires it
/// to `FoundationModelAssistant.generateStructured` and maps model-unavailability to
/// `EditInterpretationError.unavailable`.
public struct FoundationModelEditInterpreter: EditInterpreting {
    public typealias Generate = @Sendable (
        _ instruction: String,
        _ element: InterpretedElementContext
    ) async throws -> GeneratedInterpretedEdit

    private let generate: Generate

    /// Testable initializer — inject a canned `generate` closure instead of the live model.
    public init(generate: @escaping Generate) {
        self.generate = generate
    }

    /// App-wide production wiring. Builds a prompt from the instruction and element context,
    /// resolves `siteID` and `siteDirectory` from the element context (threaded through by
    /// `perform()` from the `ElementEntity`), and calls
    /// `FoundationModelAssistant.generateStructured`. Surfaces `AssistantError.unavailable`
    /// as `EditInterpretationError.unavailable`.
    ///
    /// This initializer carries no per-site state — it is safe to register once at app startup
    /// via `AppDependencyManager` and reuse across all edits.
    public init(assistant: FoundationModelAssistant) {
        self.generate = { instruction, element in
            guard let siteID = element.siteID, let siteDirectory = element.siteDirectory else {
                throw EditInterpretationError.siteUnavailable("siteID/siteDirectory not provided in element context")
            }
            let prompt = Self.buildPrompt(instruction: instruction, element: element)
            let context = AssistantContext(
                siteID: siteID,
                siteDirectory: siteDirectory,
                currentPageRoute: element.pagePath
            )
            do {
                return try await assistant.generateStructured(
                    prompt: prompt,
                    context: context,
                    resultType: GeneratedInterpretedEdit.self
                )
            } catch let e as AssistantError {
                throw EditInterpretationError.unavailable(String(describing: e))
            }
        }
    }

    // MARK: EditInterpreting

    public func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit {
        let g = try await generate(instruction, element)
        let kind: InterpretedEditKind = switch g.kind {
        case .text: .text
        case .attribute: .attribute
        case .style: .style
        }
        return InterpretedEdit(
            kind: kind,
            newText: g.newText.isEmpty ? nil : g.newText,
            attributeName: g.attributeName.isEmpty ? nil : g.attributeName,
            attributeValue: g.attributeValue.isEmpty ? nil : g.attributeValue,
            styleProperty: g.styleProperty.isEmpty ? nil : g.styleProperty,
            styleValue: g.styleValue.isEmpty ? nil : g.styleValue,
            summary: g.summary
        )
    }

    // MARK: Private

    static func buildPrompt(instruction: String, element: InterpretedElementContext) -> String {
        var lines = [
            "Interpret this edit instruction for a website element.",
            "Element: <\(element.tag)>" + (element.currentText.map { " with text \"\($0)\"" } ?? ""),
            "Page: \(element.pagePath)",
            "Instruction: \(instruction)",
            "Choose exactly one kind (text / attribute / style) and fill only that kind's fields.",
        ]
        return lines.joined(separator: "\n")
    }
}
#endif
