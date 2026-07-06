import Foundation
import Testing
@testable import AnglesiteCore

struct ComponentCanvasMessagesTests {
    @Test("Decodes a canvas selection") func decodesSelection() {
        let body: [String: Any] = [
            "type": "anglesite:canvas-selection",
            "file": "/site/src/components/Card.astro",
            "line": 7,
            "column": 1,
        ]
        guard case .success(let msg) = CanvasSelectionMessage.decode(from: body) else {
            Issue.record("expected success")
            return
        }
        #expect(msg.file == "/site/src/components/Card.astro")
        #expect(msg.line == 7)
        #expect(msg.column == 1)
    }

    @Test("Selection tolerates null loc (click on unannotated chrome)") func decodesNullLoc() {
        let body: [String: Any] = ["type": "anglesite:canvas-selection", "file": NSNull(), "line": NSNull(), "column": NSNull()]
        guard case .success(let msg) = CanvasSelectionMessage.decode(from: body) else {
            Issue.record("expected success")
            return
        }
        #expect(msg.file == nil)
        #expect(msg.line == nil)
    }

    @Test("Rejects wrong type tags") func rejectsWrongType() {
        let result = CanvasSelectionMessage.decode(from: ["type": "anglesite:apply-edit"])
        guard case .failure(.wrongType) = result else {
            Issue.record("expected wrongType")
            return
        }
    }

    @Test("Decodes computed styles") func decodesStyles() {
        let body: [String: Any] = [
            "type": "anglesite:computed-styles",
            "styles": ["display": "block", "color": "rgb(0, 0, 0)"],
        ]
        guard case .success(let report) = ComputedStylesReport.decode(from: body) else {
            Issue.record("expected success")
            return
        }
        #expect(report.styles["display"] == "block")
    }

    @Test("Computed styles reject a non-dictionary payload") func rejectsBadStyles() {
        let result = ComputedStylesReport.decode(from: ["type": "anglesite:computed-styles", "styles": "nope"])
        guard case .failure(.malformed) = result else {
            Issue.record("expected malformed")
            return
        }
    }
}
