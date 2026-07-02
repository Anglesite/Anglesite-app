// Tests/AnglesiteCoreTests/PageCopySuggestionTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("PageCopySuggestion")
struct PageCopySuggestionTests {
    @Test("NoopPageCopyGenerator always returns nil")
    func noopReturnsNil() async {
        let result = await NoopPageCopyGenerator().suggestDescription(
            title: "About", siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")
        )
        #expect(result == nil)
    }
}
