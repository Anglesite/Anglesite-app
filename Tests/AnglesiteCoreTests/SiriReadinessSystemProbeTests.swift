// Tests/AnglesiteCoreTests/SiriReadinessSystemProbeTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct SiriReadinessSystemProbeTests {
    @Test func osRuntime_meetsMinimum_isOk() async {
        let probe = OSRuntimeProbe(
            version: OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0),
            minimumMajor: 27
        )
        let finding = await probe.check()
        #expect(finding.id == "os.runtime")
        #expect(finding.level == .ok)
    }

    @Test func osRuntime_belowMinimum_isFailure_withRemediation() async {
        let probe = OSRuntimeProbe(
            version: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            minimumMajor: 27
        )
        let finding = await probe.check()
        #expect(finding.level == .failure)
        #expect(finding.remediation != nil)
    }

    @Test func foundationModels_available_isOk() async {
        let probe = FoundationModelsProbe(availability: { .available })
        let finding = await probe.check()
        #expect(finding.id == "foundation.models")
        #expect(finding.level == .ok)
    }

    @Test func foundationModels_appleIntelligenceOff_isWarning_withRemediation() async {
        let probe = FoundationModelsProbe(availability: { .appleIntelligenceNotEnabled })
        let finding = await probe.check()
        #expect(finding.level == .warning)
        #expect(finding.remediation != nil)
    }

    @Test func foundationModels_deviceNotEligible_isUnsupported() async {
        let probe = FoundationModelsProbe(availability: { .deviceNotEligible })
        let finding = await probe.check()
        #expect(finding.level == .unsupported)
    }

    @Test func foundationModels_modelNotReady_isWarning() async {
        let probe = FoundationModelsProbe(availability: { .modelNotReady })
        let finding = await probe.check()
        #expect(finding.level == .warning)
    }

    @Test func foundationModels_unknown_isWarning() async {
        let probe = FoundationModelsProbe(availability: { .unknown("test") })
        let finding = await probe.check()
        #expect(finding.level == .warning)
    }
}
