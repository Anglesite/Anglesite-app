import Testing
import Foundation
@testable import AnglesiteCore

struct SSEFrameParserTests {
    @Test("Single data line is one payload") func singleDataLine() {
        let payloads = SSEFrameParser.dataPayloads(in: "data: {\"id\":1}\n\n")
        #expect(payloads == ["{\"id\":1}"])
    }

    @Test("event and id fields are ignored; only data is collected") func ignoresNonData() {
        let text = "event: message\nid: 42\ndata: {\"ok\":true}\n\n"
        #expect(SSEFrameParser.dataPayloads(in: text) == ["{\"ok\":true}"])
    }

    @Test("multi-line data is joined with newlines") func multiLineData() {
        let text = "data: line1\ndata: line2\n\n"
        #expect(SSEFrameParser.dataPayloads(in: text) == ["line1\nline2"])
    }

    @Test("multiple events split on blank lines") func multipleEvents() {
        let text = "data: a\n\ndata: b\n\n"
        #expect(SSEFrameParser.dataPayloads(in: text) == ["a", "b"])
    }

    @Test("a trailing event without a final blank line is still emitted") func trailingEvent() {
        let text = "data: a\n\ndata: b\n"
        #expect(SSEFrameParser.dataPayloads(in: text) == ["a", "b"])
    }
}
