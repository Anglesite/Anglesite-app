import Testing
@testable import AnglesiteCore

@Suite struct DependencyVersionComparatorTests {
    @Test func detectsANewerMajorVersion() {
        #expect(DependencyVersionComparator.isNewer("^6.4.8", than: "^5.0.0") == true)
    }

    @Test func detectsAnOlderVersionIsNotNewer() {
        #expect(DependencyVersionComparator.isNewer("^5.0.0", than: "^6.4.8") == false)
    }

    @Test func equalVersionsAreNotNewer() {
        #expect(DependencyVersionComparator.isNewer("^6.4.8", than: "^6.4.8") == false)
    }

    @Test func toleratesDifferentRangePrefixCharacters() {
        #expect(DependencyVersionComparator.isNewer("~4.0.0", than: ">=3.9.9") == true)
    }

    @Test func treatsAMissingPatchComponentAsZero() {
        #expect(DependencyVersionComparator.isNewer("^6.4", than: "^6.4.8") == false)
        #expect(DependencyVersionComparator.isNewer("^6.5", than: "^6.4.8") == true)
    }

    @Test func toleratesAPreReleaseSuffixOnTheLastComponent() {
        #expect(DependencyVersionComparator.isNewer("^6.4.8-beta.1", than: "^6.4.7") == true)
    }

    @Test func isNilWhenEitherSideHasNoParseableVersion() {
        #expect(DependencyVersionComparator.isNewer("*", than: "^6.4.8") == nil)
        #expect(DependencyVersionComparator.isNewer("^6.4.8", than: "workspace:*") == nil)
        #expect(DependencyVersionComparator.isNewer("latest", than: "next") == nil)
    }
}
