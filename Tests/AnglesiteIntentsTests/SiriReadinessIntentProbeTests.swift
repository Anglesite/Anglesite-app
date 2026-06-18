// Tests/AnglesiteIntentsTests/SiriReadinessIntentProbeTests.swift
import Testing
import AnglesiteCore
@testable import AnglesiteIntents

@Suite struct SiriReadinessIntentProbeTests {
    @Test func appIntents_withShortcuts_isOk() async {
        let finding = await AppIntentsRegistrationProbe(shortcutCount: 9).check()
        #expect(finding.id == "intents.registration")
        #expect(finding.level == .ok)
    }

    @Test func appIntents_noShortcuts_isWarning() async {
        let finding = await AppIntentsRegistrationProbe(shortcutCount: 0).check()
        #expect(finding.level == .warning)
        #expect(finding.remediation != nil)
    }

    @Test func appIntents_defaultUsesRealShortcuts() async {
        // The real provider ships curated shortcuts, so the default init must report ok.
        let finding = await AppIntentsRegistrationProbe().check()
        #expect(finding.level == .ok)
    }

    @Test func viewAnnotations_compiled_isOk() async {
        let finding = await ViewAnnotationsProbe(compiled: true).check()
        #expect(finding.id == "view.annotations")
        #expect(finding.level == .ok)
    }

    @Test func viewAnnotations_notCompiled_isUnsupported() async {
        let finding = await ViewAnnotationsProbe(compiled: false).check()
        #expect(finding.level == .unsupported)
    }

    @Test func mcpBridge_unregistered_isUnsupported() async {
        let finding = await SystemMCPBridgeProbe(registered: false).check()
        #expect(finding.id == "mcp.bridge")
        #expect(finding.level == .unsupported)
    }

    @Test func mcpBridge_registered_isOk() async {
        let finding = await SystemMCPBridgeProbe(registered: true).check()
        #expect(finding.level == .ok)
    }
}
