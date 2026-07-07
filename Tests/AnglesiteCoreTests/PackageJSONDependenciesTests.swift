import Testing
@testable import AnglesiteCore

@Suite struct PackageJSONDependenciesTests {
    static let fixture = """
    {
      "name": "anglesite-site",
      "type": "module",
      "version": "0.0.1",
      "dependencies": {
        "@astrojs/rss": "^4.0.0",
        "astro": "^5.0.0"
      },
      "devDependencies": {
        "typescript": "^5.9.3"
      }
    }
    """

    @Test func extractsBothDependencySections() throws {
        let deps = try PackageJSONDependencies.extract(from: Self.fixture)
        #expect(deps == ["@astrojs/rss": "^4.0.0", "astro": "^5.0.0", "typescript": "^5.9.3"])
    }

    @Test func throwsOnInvalidJSON() {
        #expect(throws: PackageJSONDependencies.ExtractionError.self) {
            _ = try PackageJSONDependencies.extract(from: "not json")
        }
    }

    @Test func extractsEmptyMapWhenNoDependencySectionsPresent() throws {
        let deps = try PackageJSONDependencies.extract(from: "{\"name\": \"x\"}")
        #expect(deps.isEmpty)
    }

    @Test func applyRewritesOnlyTheAcceptedPackagesRangeString() {
        let offers = [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")]
        let updated = PackageJSONDependencies.apply(offers, to: Self.fixture)
        #expect(updated.contains("\"astro\": \"^6.4.8\""))
        #expect(!updated.contains("\"astro\": \"^5.0.0\""))
        // Untouched: everything else, including formatting and the other dependency.
        #expect(updated.contains("\"@astrojs/rss\": \"^4.0.0\""))
        #expect(updated.contains("\"typescript\": \"^5.9.3\""))
        #expect(updated.contains("\"version\": \"0.0.1\""))
    }

    @Test func applyWithNoOffersReturnsTheTextUnchanged() {
        #expect(PackageJSONDependencies.apply([], to: Self.fixture) == Self.fixture)
    }

    @Test func applyIsSafeWhenThePackageNameIsNotPresent() {
        let offers = [DependencyUpdateOffer(name: "does-not-exist", currentRange: "^1.0.0", offeredRange: "^2.0.0")]
        #expect(PackageJSONDependencies.apply(offers, to: Self.fixture) == Self.fixture)
    }
}
