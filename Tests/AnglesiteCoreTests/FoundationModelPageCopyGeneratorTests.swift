import Foundation
import Testing
@testable import AnglesiteCore

// FoundationModels is absent on the CI runner; these only compile/run under Xcode 27.
#if compiler(>=6.4)
@Suite struct FoundationModelPageCopyGeneratorTests {
    @Test func promptIncludesTheTitle() {
        let prompt = FoundationModelPageCopyGenerator.prompt(for: "About Us")
        #expect(prompt.contains("About Us"))
        #expect(prompt.lowercased().contains("meta description"))
    }

    @Test func normalizedDescriptionTrimsWhitespace() {
        #expect(FoundationModelPageCopyGenerator.normalizedDescription(" Meet the team. ") == "Meet the team.")
    }

    @Test func normalizedDescriptionCollapsesBlankToNil() {
        #expect(FoundationModelPageCopyGenerator.normalizedDescription("") == nil)
        #expect(FoundationModelPageCopyGenerator.normalizedDescription("   ") == nil)
    }

    @Test func emptyTitleReturnsNilWithoutModel() async {
        // Whitespace-only title must short-circuit to nil and never invoke the on-device model,
        // so this is deterministic on machines with or without Apple Intelligence.
        let result = await FoundationModelPageCopyGenerator().suggestDescription(
            title: "   ", siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")
        )
        #expect(result == nil)
    }
}
#endif

@Suite struct PageCopyGeneratorFactoryTests {
    // The factory's product differs per toolchain (real conformer under Xcode 27, Noop on CI),
    // but BOTH short-circuit a whitespace-only title to nil before touching any model — a real
    // behavioral assertion that holds everywhere and never invokes Apple Intelligence.
    @Test func makeDefaultProductShortCircuitsEmptyTitle() async {
        let result = await PageCopyGeneratorFactory.makeDefault().suggestDescription(
            title: "   ", siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")
        )
        #expect(result == nil)
    }
}
