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

    @Test("SettingsGatedPageCopyGenerator skips the base generator when disabled")
    func settingsGatedSkipsWhenDisabled() async {
        let base = StubGenerator(suggestion: PageCopySuggestion(description: "Should not be seen."))
        let gated = SettingsGatedPageCopyGenerator(isEnabled: { false }, base: base)
        let result = await gated.suggestDescription(title: "About", siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s"))
        #expect(result == nil)
        #expect(await base.callCount == 0)
    }

    @Test("SettingsGatedPageCopyGenerator delegates to the base generator when enabled")
    func settingsGatedDelegatesWhenEnabled() async {
        let base = StubGenerator(suggestion: PageCopySuggestion(description: "Meet the team."))
        let gated = SettingsGatedPageCopyGenerator(isEnabled: { true }, base: base)
        let result = await gated.suggestDescription(title: "About", siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s"))
        #expect(result == PageCopySuggestion(description: "Meet the team."))
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct StubGenerator: PageCopyGenerating {
    let suggestion: PageCopySuggestion?
    private let counter = CallCounter()
    var callCount: Int { get async { await counter.count } }
    func suggestDescription(title: String, siteID: String, siteDirectory: URL) async -> PageCopySuggestion? {
        await counter.increment()
        return suggestion
    }
}
