import Testing
@testable import AnglesiteCore

@Suite struct DependencySyncTests {
    @Test func offersABumpWhenSiteMatchesBaselineButTemplateMovedForward() {
        let offers = DependencySync.diff(
            site: ["astro": "^5.0.0"],
            baseline: ["astro": "^5.0.0"],
            template: ["astro": "^6.4.8"]
        )
        #expect(offers == [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")])
    }

    @Test func leavesAUserCustomizedPackageAlone() {
        // Site's range no longer matches the baseline -> the user edited it deliberately.
        let offers = DependencySync.diff(
            site: ["astro": "^5.1.0"],
            baseline: ["astro": "^5.0.0"],
            template: ["astro": "^6.4.8"]
        )
        #expect(offers.isEmpty)
    }

    @Test func doesNothingWhenSiteBaselineAndTemplateAllAgree() {
        let offers = DependencySync.diff(
            site: ["astro": "^6.4.8"],
            baseline: ["astro": "^6.4.8"],
            template: ["astro": "^6.4.8"]
        )
        #expect(offers.isEmpty)
    }

    @Test func legacySiteWithNoBaselineFallsBackToADirectDiff() {
        let offers = DependencySync.diff(
            site: ["astro": "^5.0.0"],
            baseline: nil,
            template: ["astro": "^6.4.8"]
        )
        #expect(offers == [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")])
    }

    @Test func neverOffersToAddAPackageTheSiteDoesNotHave() {
        let offers = DependencySync.diff(
            site: [:],
            baseline: [:],
            template: ["astro-embed": "^0.13.0"]
        )
        #expect(offers.isEmpty)
    }

    @Test func neverOffersToRemoveAPackageTheTemplateNoLongerHas() {
        let offers = DependencySync.diff(
            site: ["some-deprecated-package": "^1.0.0"],
            baseline: ["some-deprecated-package": "^1.0.0"],
            template: [:]
        )
        #expect(offers.isEmpty)
    }

    @Test func skipsAnIncomparableVersionRatherThanGuessing() {
        let offers = DependencySync.diff(
            site: ["astro": "workspace:*"],
            baseline: ["astro": "workspace:*"],
            template: ["astro": "^6.4.8"]
        )
        #expect(offers.isEmpty)
    }

    @Test func handlesMultiplePackagesSortedByName() {
        let offers = DependencySync.diff(
            site: ["astro": "^5.0.0", "tsx": "^3.0.0"],
            baseline: ["astro": "^5.0.0", "tsx": "^3.0.0"],
            template: ["astro": "^6.4.8", "tsx": "^4.0.0"]
        )
        #expect(offers == [
            DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8"),
            DependencyUpdateOffer(name: "tsx", currentRange: "^3.0.0", offeredRange: "^4.0.0"),
        ])
    }
}
