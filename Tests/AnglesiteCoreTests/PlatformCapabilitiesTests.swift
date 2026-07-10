import Foundation
import Testing
@testable import AnglesiteCore

@Suite("PlatformCapabilities")
struct PlatformCapabilitiesTests {
    @Test("modelTier is derived from hasAssistant")
    func tierMatchesAssistant() {
        let expected: PlatformCapabilities.ModelTier =
            PlatformCapabilities.hasAssistant ? .onDevice : .unavailable
        #expect(PlatformCapabilities.modelTier == expected)
    }

    @Test("capability flags match this build's actual imports")
    func flagsMatchBuild() {
        #if canImport(NaturalLanguage)
        #expect(PlatformCapabilities.hasEmbeddings)
        #else
        #expect(!PlatformCapabilities.hasEmbeddings)
        #endif

        #if compiler(>=6.4) && canImport(FoundationModels)
        #expect(PlatformCapabilities.hasAssistant)
        #else
        #expect(!PlatformCapabilities.hasAssistant)
        #endif
    }
}
