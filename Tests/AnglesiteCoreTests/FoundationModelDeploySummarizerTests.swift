import Foundation
import Testing
@testable import AnglesiteCore

// FoundationModels is absent on the CI runner; these only compile/run under Xcode 27.
#if compiler(>=6.4)
@Suite struct FoundationModelDeploySummarizerTests {
    @Test func promptIncludesTheLog() {
        let prompt = FoundationModelDeploySummarizer.prompt(for: "✘ [ERROR] Could not resolve \"./x\"")
        #expect(prompt.contains("Could not resolve"))
        #expect(prompt.lowercased().contains("deploy"))
    }

    @Test func emptyLogReturnsNilWithoutModel() async {
        // Whitespace-only log must short-circuit to nil and never invoke the on-device model,
        // so this is deterministic on machines with or without Apple Intelligence.
        let result = await FoundationModelDeploySummarizer().summarize(
            failureLog: "   ", siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")
        )
        #expect(result == nil)
    }
}
#endif

@Suite struct DeploySummarizerFactoryTests {
    // The factory's product differs per toolchain (real conformer under Xcode 27, Noop on CI),
    // but BOTH short-circuit a whitespace-only log to nil before touching any model — a real
    // behavioral assertion that holds everywhere and never invokes Apple Intelligence.
    @Test func makeDefaultProductShortCircuitsEmptyLog() async {
        let result = await DeploySummarizerFactory.makeDefault().summarize(
            failureLog: "   ", siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")
        )
        #expect(result == nil)
    }
}
