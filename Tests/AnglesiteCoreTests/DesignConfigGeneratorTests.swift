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

    @Test func warmLowRegisterAxesPickHumanistSansPairing() {
        // Index 2: humanist-sans+humanist-sans wins when temperature is high,
        // register is low, voice is low. Score formula: temp*1.5 + (1-reg)*1 + (1-voice)*0.5
        let axes = DesignAxes(temperature: 1.0, weight: 0.5, register: 0.0, time: 0.5, voice: 0.0)
        let result = DesignConfigGenerator.typography(for: axes)
        #expect(result.pairing == "humanist-sans+humanist-sans")
    }

    @Test func classicAuthorityWithWarmTemperaturePicksClassicSerifHumanistSansPairing() {
        // Index 3: classic-serif+humanist-sans wins with low time, high register, high temperature.
        // Score formula: (1-time)*1.5 + register*1 + temp*0.8
        let axes = DesignAxes(temperature: 1.0, weight: 0.5, register: 0.8, time: 0.21, voice: 1.0)
        let result = DesignConfigGenerator.typography(for: axes)
        #expect(result.pairing == "classic-serif+humanist-sans")
    }

    @Test func contemporaryHighRegisterAxesPickModernSansHumanistSansPairing() {
        // Index 4: modern-sans+humanist-sans wins with high time, high temperature, high register.
        // Score formula: time*1 + temp*0.8 + (1-register)*0.8
        // With high register, (1-register)*0.8 is small, allowing time and temp to dominate.
        let axes = DesignAxes(temperature: 0.95, weight: 0.5, register: 0.9, time: 0.95, voice: 0.5)
        let result = DesignConfigGenerator.typography(for: axes)
        #expect(result.pairing == "modern-sans+humanist-sans")
    }

    private func parseRem(_ value: String) -> Double {
        Double(value.replacingOccurrences(of: "rem", with: "")) ?? 0
    }
}
