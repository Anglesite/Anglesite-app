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

    @Test("a query string and fragment in the route are carried over, not encoded into the path")
    func routeWithQueryAndFragment() {
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "/about?preview=1")
                == URL(string: "http://localhost:4321/about?preview=1")!)
        #expect(PreviewNavigation.targetURL(base: Self.base, route: "/about#top")
                == URL(string: "http://localhost:4321/about#top")!)
    }

    @Test("applyingEsiPreviewMode: unprocessed=false leaves the URL untouched")
    func esiPreviewModeOffIsNoop() {
        #expect(PreviewNavigation.applyingEsiPreviewMode(Self.base, unprocessed: false) == Self.base)
    }

    @Test("applyingEsiPreviewMode: unprocessed=true appends the query parameter")
    func esiPreviewModeOnAppendsQuery() {
        #expect(PreviewNavigation.applyingEsiPreviewMode(Self.base, unprocessed: true)
                == URL(string: "http://localhost:4321/?esiPreview=unprocessed")!)
    }

    @Test("applyingEsiPreviewMode: preserves an existing query item")
    func esiPreviewModePreservesExistingQuery() {
        let withQuery = URL(string: "http://localhost:4321/about?preview=1")!
        let result = PreviewNavigation.applyingEsiPreviewMode(withQuery, unprocessed: true)
        let comps = URLComponents(url: result, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["preview"] == "1")
        #expect(items["esiPreview"] == "unprocessed")
    }

    @Test("applyingEsiPreviewMode: replaces a stale esiPreview value rather than duplicating it")
    func esiPreviewModeReplacesStaleValue() {
        let stale = URL(string: "http://localhost:4321/?esiPreview=live")!
        let result = PreviewNavigation.applyingEsiPreviewMode(stale, unprocessed: true)
        let comps = URLComponents(url: result, resolvingAgainstBaseURL: false)!
        let matches = (comps.queryItems ?? []).filter { $0.name == "esiPreview" }
        #expect(matches.count == 1)
        #expect(matches.first?.value == "unprocessed")
    }
}
