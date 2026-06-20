import Testing
import Foundation
@testable import AnglesiteCore

struct SiteContentGraphStreamTests {
    private func makePage(_ siteID: String, route: String) -> SiteContentGraph.Page {
        SiteContentGraph.Page(
            id: "\(siteID):page:\(route)", siteID: siteID, route: route,
            filePath: "/tmp/\(route).astro", title: route, lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("changeStream yields the siteID on a real mutation")
    func yieldsOnMutation() async throws {
        let graph = SiteContentGraph()
        var iterator = (await graph.changeStream()).makeAsyncIterator()
        await graph.upsertPage(makePage("siteA", route: "/about/"))
        let received = await iterator.next()
        #expect(received == "siteA")
    }

    @Test("two independent subscribers both receive the change")
    func broadcastsToAll() async throws {
        let graph = SiteContentGraph()
        var it1 = (await graph.changeStream()).makeAsyncIterator()
        var it2 = (await graph.changeStream()).makeAsyncIterator()
        await graph.upsertPage(makePage("siteB", route: "/x/"))
        let a = await it1.next()
        let b = await it2.next()
        #expect(a == "siteB")
        #expect(b == "siteB")
    }

    @Test("an equal upsert does not emit (real-mutation only)")
    func noEmitOnEqualUpsert() async throws {
        let graph = SiteContentGraph()
        let page = makePage("siteC", route: "/y/")
        await graph.upsertPage(page)              // first insert emits
        var it = (await graph.changeStream()).makeAsyncIterator()
        await graph.upsertPage(page)              // equal → no emit
        await graph.upsertPage(makePage("siteC", route: "/z/")) // emits
        let received = await it.next()
        #expect(received == "siteC")              // the /z/ emit, not a phantom /y/ emit
    }
}
