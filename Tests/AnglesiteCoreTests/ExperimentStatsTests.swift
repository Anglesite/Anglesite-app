import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ExperimentStatsTests {
    // MARK: - Exact probability

    @Test func evenPosteriorsGiveFiftyFifty() {
        // Identical evidence on both sides — P(B > A) must be exactly symmetric.
        let p = ExperimentStats.probabilityBBeatsA(alphaA: 11, betaA: 91, alphaB: 11, betaB: 91)
        #expect(abs(p - 0.5) < 1e-9)
    }

    @Test func knownClosedFormValue() {
        // Tiny case checkable by hand: A ~ Beta(1,1), B ~ Beta(2,1) → P(B > A) = 2/3.
        let p = ExperimentStats.probabilityBBeatsA(alphaA: 1, betaA: 1, alphaB: 2, betaB: 1)
        #expect(abs(p - 2.0 / 3.0) < 1e-9)
    }

    @Test func complementIsSymmetric() {
        // P(B > A) + P(A > B) = 1 for continuous posteriors.
        let p1 = ExperimentStats.probabilityBBeatsA(alphaA: 21, betaA: 480, alphaB: 33, betaB: 468)
        let p2 = ExperimentStats.probabilityBBeatsA(alphaA: 33, betaA: 468, alphaB: 21, betaB: 480)
        #expect(abs(p1 + p2 - 1) < 1e-9)
    }

    @Test func logGammaMatchesKnownValues() {
        // Γ(5) = 24, Γ(0.5) = √π.
        #expect(abs(ExperimentStats.logGamma(5) - log(24.0)) < 1e-10)
        #expect(abs(ExperimentStats.logGamma(0.5) - log(Double.pi.squareRoot())) < 1e-10)
    }

    // MARK: - analyze

    @Test func clearTreatmentWinIsDeclared() {
        let control = ExperimentStats.Variant(name: "control", impressions: 1000, conversions: 32)
        let treatment = ExperimentStats.Variant(name: "variant-a", impressions: 1000, conversions: 61)
        let result = ExperimentStats.analyze(control: control, treatment: treatment)
        #expect(result.winner == .treatment(name: "variant-a"))
        #expect(result.probabilityTreatmentBeatsControl > 0.95)
        #expect(result.liftPercent > 0)
    }

    @Test func clearControlWinIsDeclared() {
        let control = ExperimentStats.Variant(name: "control", impressions: 1000, conversions: 61)
        let treatment = ExperimentStats.Variant(name: "variant-a", impressions: 1000, conversions: 32)
        let result = ExperimentStats.analyze(control: control, treatment: treatment)
        #expect(result.winner == .control(name: "control"))
        #expect(result.liftPercent < 0)
    }

    @Test func closeRaceIsInconclusive() {
        let control = ExperimentStats.Variant(name: "control", impressions: 500, conversions: 20)
        let treatment = ExperimentStats.Variant(name: "variant-a", impressions: 500, conversions: 22)
        let result = ExperimentStats.analyze(control: control, treatment: treatment)
        #expect(result.winner == .inconclusive)
    }

    @Test func analysisIsDeterministic() {
        let control = ExperimentStats.Variant(name: "control", impressions: 812, conversions: 26)
        let treatment = ExperimentStats.Variant(name: "variant-a", impressions: 794, conversions: 31)
        let first = ExperimentStats.analyze(control: control, treatment: treatment)
        let second = ExperimentStats.analyze(control: control, treatment: treatment)
        #expect(first == second)
    }

    @Test func zeroImpressionsDoesNotCrash() {
        let control = ExperimentStats.Variant(name: "control", impressions: 0, conversions: 0)
        let treatment = ExperimentStats.Variant(name: "variant-a", impressions: 0, conversions: 0)
        let result = ExperimentStats.analyze(control: control, treatment: treatment)
        #expect(result.winner == .inconclusive)
        #expect(abs(result.probabilityTreatmentBeatsControl - 0.5) < 1e-9)
    }

    @Test func variantClampsImpossibleCounts() {
        // conversions > impressions is a data error; the initializer clamps instead of trapping.
        let variant = ExperimentStats.Variant(name: "x", impressions: 10, conversions: 25)
        #expect(variant.conversions == 10)
        let negative = ExperimentStats.Variant(name: "y", impressions: -5, conversions: -2)
        #expect(negative.impressions == 0 && negative.conversions == 0)
    }

    // MARK: - Data sufficiency

    @Test func sufficiencyRequiresFloorOnBothVariants() {
        let thin = ExperimentStats.Variant(name: "a", impressions: 499, conversions: 5)
        let thick = ExperimentStats.Variant(name: "b", impressions: 800, conversions: 9)
        #expect(!ExperimentStats.hasSufficientData(control: thin, treatment: thick))
        #expect(ExperimentStats.hasSufficientData(control: thick, treatment: thick))
    }

    // MARK: - Sample-ratio mismatch

    @Test func balancedSplitIsNotMismatch() {
        let control = ExperimentStats.Variant(name: "a", impressions: 5023, conversions: 100)
        let treatment = ExperimentStats.Variant(name: "b", impressions: 4977, conversions: 100)
        #expect(!ExperimentStats.hasSampleRatioMismatch(control: control, treatment: treatment))
    }

    @Test func sixtyFortySplitAtVolumeIsMismatch() {
        // The skill's own example: 60/40 on a configured 50/50 split signals a technical issue.
        let control = ExperimentStats.Variant(name: "a", impressions: 6000, conversions: 100)
        let treatment = ExperimentStats.Variant(name: "b", impressions: 4000, conversions: 100)
        #expect(ExperimentStats.hasSampleRatioMismatch(control: control, treatment: treatment))
    }

    @Test func tinyTrafficNeverFlagsMismatch() {
        let control = ExperimentStats.Variant(name: "a", impressions: 30, conversions: 1)
        let treatment = ExperimentStats.Variant(name: "b", impressions: 10, conversions: 1)
        #expect(!ExperimentStats.hasSampleRatioMismatch(control: control, treatment: treatment))
    }

    @Test func honorsConfiguredWeights() {
        // A 70/30 observed split is fine when the experiment was configured 70/30.
        let control = ExperimentStats.Variant(name: "a", impressions: 7000, conversions: 100)
        let treatment = ExperimentStats.Variant(name: "b", impressions: 3000, conversions: 100)
        #expect(!ExperimentStats.hasSampleRatioMismatch(
            control: control, treatment: treatment, expectedControlWeight: 0.7))
        #expect(ExperimentStats.hasSampleRatioMismatch(
            control: control, treatment: treatment, expectedControlWeight: 0.5))
    }

    // MARK: - Plain-language summary

    @Test func treatmentWinSummaryNamesTheVariant() {
        let control = ExperimentStats.Variant(name: "control", impressions: 1000, conversions: 32)
        let treatment = ExperimentStats.Variant(name: "Fresh Eggs Headline", impressions: 1000, conversions: 61)
        let result = ExperimentStats.analyze(control: control, treatment: treatment)
        let summary = ExperimentStats.formatSummary(experimentName: "Homepage Hero", result: result)
        #expect(summary.contains("**Homepage Hero**"))
        #expect(summary.contains("Fresh Eggs Headline is outperforming the original"))
        #expect(summary.contains("Original: "))
    }

    @Test func controlWinSummaryUsesOriginalPhrasing() {
        // Regression guard for the ab-stats.ts port: the TS version compared winner to the
        // literal string "control", so a control named anything else fell into the treatment
        // branch. The Swift port keys off the Winner case instead.
        let control = ExperimentStats.Variant(name: "current-hero", impressions: 1000, conversions: 61)
        let treatment = ExperimentStats.Variant(name: "variant-a", impressions: 1000, conversions: 32)
        let result = ExperimentStats.analyze(control: control, treatment: treatment)
        let summary = ExperimentStats.formatSummary(experimentName: "Hero Test", result: result)
        #expect(summary.contains("The original is performing better"))
    }

    @Test func inconclusiveSummarySaysTooCloseToCall() {
        let control = ExperimentStats.Variant(name: "control", impressions: 100, conversions: 4)
        let treatment = ExperimentStats.Variant(name: "variant-a", impressions: 100, conversions: 5)
        let result = ExperimentStats.analyze(control: control, treatment: treatment)
        let summary = ExperimentStats.formatSummary(experimentName: "CTA Test", result: result)
        #expect(summary.contains("Too close to call"))
    }

    // MARK: - Suggestion playbook

    @Test func playbookLeadsWithHeroHeadline() {
        // The retired skill's priority order: headline first, narrative structure last.
        #expect(ExperimentStats.suggestionPlaybook.first?.title == "Hero headline")
        #expect(ExperimentStats.suggestionPlaybook.last?.title == "Page narrative structure")
        #expect(ExperimentStats.suggestionPlaybook.count == 6)
        #expect(ExperimentStats.suggestionPlaybook.allSatisfy { !$0.rationale.isEmpty })
    }
}
