import Testing
@testable import AnglesiteIntents

@MainActor
struct WindowRouterTests {
    @Test("requestOpen with a route sets the open trigger and stores the route once")
    func requestOpenWithRoute() {
        let router = WindowRouter.shared
        router.requested = nil
        _ = router.consumeRoute(for: "siteA")   // clear any prior state

        router.requestOpen(siteID: "siteA", route: "/about")
        #expect(router.requested == "siteA")
        #expect(router.consumeRoute(for: "siteA") == "/about")
        // Consume-once: a second read is nil.
        #expect(router.consumeRoute(for: "siteA") == nil)
    }

    @Test("requestOpen without a route stores no route")
    func requestOpenNoRoute() {
        let router = WindowRouter.shared
        _ = router.consumeRoute(for: "siteB")
        router.requestOpen(siteID: "siteB")
        #expect(router.requested == "siteB")
        #expect(router.consumeRoute(for: "siteB") == nil)
    }

    @Test("a route requested for one site is not consumed by another")
    func routeIsPerSite() {
        let router = WindowRouter.shared
        _ = router.consumeRoute(for: "siteA")
        _ = router.consumeRoute(for: "siteB")
        router.requestOpen(siteID: "siteA", route: "/contact")
        #expect(router.consumeRoute(for: "siteB") == nil)
        #expect(router.consumeRoute(for: "siteA") == "/contact")
    }
}
