import XCTest
@testable import AnglesiteCore

final class AnnotationFeedTests: XCTestCase {
    func testDecodesSinglePluginAnnotation() throws {
        let json = #"""
        [{"id":"abc12345","path":"/about","selector":"h1","text":"tighter tone here","resolved":false,"createdAt":"2026-05-24T10:00:00Z"}]
        """#
        let parsed = try AnnotationFeedFactory.decode(jsonText: json)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "abc12345")
        XCTAssertEqual(parsed[0].path, "/about")
        XCTAssertEqual(parsed[0].text, "tighter tone here")
        XCTAssertFalse(parsed[0].resolved)
        XCTAssertNil(parsed[0].resolvedAt)
        XCTAssertNil(parsed[0].sourceFile)
    }

    func testDecodesArrayWithMixedResolvedStates() throws {
        let json = #"""
        [
          {"id":"a","path":"/","selector":"#hero","text":"a","resolved":false,"createdAt":"2026-05-24T10:00:00Z"},
          {"id":"b","path":"/contact","selector":".form","text":"b","resolved":true,"createdAt":"2026-05-23T09:00:00Z","resolvedAt":"2026-05-23T11:00:00Z","sourceFile":"src/pages/contact.astro"}
        ]
        """#
        let parsed = try AnnotationFeedFactory.decode(jsonText: json)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[1].sourceFile, "src/pages/contact.astro")
        XCTAssertTrue(parsed[1].resolved)
        XCTAssertNotNil(parsed[1].resolvedAt)
    }

    func testEmptyJSONArrayDecodesToEmpty() throws {
        XCTAssertEqual(try AnnotationFeedFactory.decode(jsonText: "[]"), [])
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try AnnotationFeedFactory.decode(jsonText: "{not json}"))
    }

    func testEmptyStringDecodesToEmpty() throws {
        XCTAssertEqual(try AnnotationFeedFactory.decode(jsonText: ""), [])
    }
}
