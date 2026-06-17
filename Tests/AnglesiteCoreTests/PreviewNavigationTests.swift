import Testing
import Foundation
@testable import AnglesiteCore

struct PreviewNavigationTests {
    static let base = URL(string: "http://localhost:4321/")!

    @Test("absolute route is composed onto the base host/port")
    func absoluteRoute() {
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "/about")
                == URL(string: "http://localhost:4321/about")!)
    }

    @Test("route without a leading slash is normalized")
    func normalizesLeadingSlash() {
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "about")
                == URL(string: "http://localhost:4321/about")!)
    }

    @Test("nested route is preserved")
    func nestedRoute() {
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "/blog/post-1")
                == URL(string: "http://localhost:4321/blog/post-1")!)
    }

    @Test("root route returns the base")
    func rootRoute() {
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "/") == Self.base)
    }

    @Test("empty / whitespace route returns the base")
    func emptyRoute() {
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "") == Self.base)
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "   ") == Self.base)
    }

    @Test("base without a trailing slash does not double up")
    func baseNoTrailingSlash() {
        let base = URL(string: "http://localhost:4321")!
        #expect(PreviewNavigation.targetURL(base: base, route: "/about")
                == URL(string: "http://localhost:4321/about")!)
    }
}
