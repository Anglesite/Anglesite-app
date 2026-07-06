import Foundation

/// JS → native messages from the component-harness canvas overlay module.
/// Wire shapes are defined in JS/edit-overlay/src/component-canvas.ts.
public enum ComponentCanvasDecodeError: Error, Equatable {
    case wrongType
    case malformed
}

public struct CanvasSelectionMessage: Sendable, Equatable {
    public static let messageType = "anglesite:canvas-selection"

    public let file: String?
    public let line: Int?
    public let column: Int?

    public init(file: String?, line: Int?, column: Int?) {
        self.file = file
        self.line = line
        self.column = column
    }

    public static func decode(from body: Any) -> Result<CanvasSelectionMessage, ComponentCanvasDecodeError> {
        guard let dict = body as? [String: Any], dict["type"] as? String == messageType else {
            return .failure(.wrongType)
        }
        return .success(CanvasSelectionMessage(
            file: dict["file"] as? String,
            line: dict["line"] as? Int,
            column: dict["column"] as? Int
        ))
    }
}

public struct ComputedStylesReport: Sendable, Equatable {
    public static let messageType = "anglesite:computed-styles"

    public let styles: [String: String]

    public init(styles: [String: String]) {
        self.styles = styles
    }

    public static func decode(from body: Any) -> Result<ComputedStylesReport, ComponentCanvasDecodeError> {
        guard let dict = body as? [String: Any], dict["type"] as? String == messageType else {
            return .failure(.wrongType)
        }
        guard let styles = dict["styles"] as? [String: String] else {
            return .failure(.malformed)
        }
        return .success(ComputedStylesReport(styles: styles))
    }
}
