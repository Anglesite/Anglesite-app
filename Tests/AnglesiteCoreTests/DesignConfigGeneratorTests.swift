// Tests/AnglesiteCoreTests/DesignConfigGeneratorTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct DesignConfigGeneratorTests {
    @Test func contemporaryAxesPickModernSansPairing() {
        let axes = DesignAxes(temperature: 0.5, weight: 0.4, register: 0.2, time: 1.0, voice: 0.5)
        #expect(DesignConfigGenerator.typography(for: axes).pairing == "modern-sans+modern-sans")
    }

    @Test func classicAuthoritativeAxesPickClassicSerifPairing() {
        let axes = DesignAxes(temperature: 0.5, weight: 0.4, register: 1.0, time: 0.0, voice: 0.1)
        #expect(DesignConfigGenerator.typography(for: axes).pairing == "classic-serif+modern-sans")
    }

    @Test func airyWeightProducesLargerSpacingThanDense() {
        let airy = DesignConfigGenerator.spacing(for: DesignAxes(temperature: 0.5, weight: 0.0, register: 0.5, time: 0.5, voice: 0.4))
        let dense = DesignConfigGenerator.spacing(for: DesignAxes(temperature: 0.5, weight: 1.0, register: 0.5, time: 0.5, voice: 0.4))
        #expect(parseRem(airy.md) > parseRem(dense.md))
    }

    @Test func playfulContemporaryAxesProduceRounderShapeThanAuthoritativeClassic() {
        let playful = DesignConfigGenerator.shape(for: DesignAxes(temperature: 0.5, weight: 0.4, register: 0.0, time: 1.0, voice: 0.4))
        let authoritative = DesignConfigGenerator.shape(for: DesignAxes(temperature: 0.5, weight: 0.4, register: 1.0, time: 0.0, voice: 0.4))
        #expect(parseRem(playful.radiusMd) > parseRem(authoritative.radiusMd))
    }

    @Test func configAssemblesAllParts() {
        let config = DesignConfigGenerator.config(axes: DesignAxesCatalog.balanced, siteType: "bakery", brandColor: nil)
        #expect(config.siteType == "bakery")
        #expect(config.axes == DesignAxesCatalog.balanced)
        #expect(config.brandColor == nil)
    }

    private func parseRem(_ value: String) -> Double {
        Double(value.replacingOccurrences(of: "rem", with: "")) ?? 0
    }
}
