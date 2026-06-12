import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `IntentEditBridge` (A.4, #138): builds an `EditMessage` from intent parameters and
/// routes it through the `EditRouter` the provider supplies, with a graceful failure when no
/// router is available. Uses a fake router + provider and an injected id so assertions are stable.
struct IntentEditBridgeTests {
    actor FakeRouter: EditRouter {
        private(set) var received: [EditMessage] = []
        private let status: EditReply.Status
        private let file: String?

        init(status: EditReply.Status = .applied, file: String? = "src/pages/about.astro") {
            self.status = status
            self.file = file
        }
        func apply(_ message: EditMessage) async -> EditReply {
            received.append(message)
            return EditReply(id: message.id, status: status, message: "from-router", file: file)
        }
    }

    private let selector: JSONValue = .object(["tag": .string("h1"), "index": .int(0)])

    private func bridge(id: String = "fixed-id", provider: @escaping IntentEditBridge.RouterProvider) -> IntentEditBridge {
        IntentEditBridge(routerProvider: provider, makeID: { id })
    }

    @Test("routes the edit through the provider's router and returns its reply")
    func routesThroughProvidedRouter() async {
        let router = FakeRouter(status: .applied)
        let edit = bridge { _ in router }

        let reply = await edit.applyEdit(siteID: "s1", filePath: "/about", selector: selector, op: "replace-text", value: .string("Hi"))

        #expect(reply.status == .applied)
        #expect(reply.file == "src/pages/about.astro")
        #expect(await router.received.count == 1)
    }

    @Test("builds the EditMessage from the intent parameters")
    func buildsEditMessage() async {
        let router = FakeRouter()
        let edit = bridge(id: "abc") { _ in router }

        _ = await edit.applyEdit(siteID: "s1", filePath: "/about", selector: selector, op: "replace-text", value: .string("Hi"))

        let msg = await router.received.first
        #expect(msg?.id == "abc")
        #expect(msg?.type == .applyEdit)
        #expect(msg?.path == "/about")
        #expect(msg?.op == "replace-text")
        #expect(msg?.value == .string("Hi"))
        #expect(msg?.selector == selector)
    }

    @Test("passes the site id to the provider for router lookup")
    func passesSiteIDToProvider() async {
        let seen = LockedBox<String?>(nil)
        let router = FakeRouter()
        let edit = bridge { siteID in seen.set(siteID); return router }

        _ = await edit.applyEdit(siteID: "/Users/x/Sites/alpha", filePath: "/", selector: selector, op: "x", value: nil)

        #expect(seen.get() == "/Users/x/Sites/alpha")
    }

    @Test("no router for the site yields a failed reply carrying the message id")
    func noRouterFails() async {
        let edit = bridge(id: "no-router") { _ in nil }

        let reply = await edit.applyEdit(siteID: "s1", filePath: "/about", selector: selector, op: "replace-text", value: nil)

        #expect(reply.status == .failed)
        #expect(reply.id == "no-router")
        #expect(reply.message?.isEmpty == false)
    }

    @Test("a failed router reply propagates unchanged")
    func propagatesRouterFailure() async {
        let router = FakeRouter(status: .failed, file: nil)
        let edit = bridge { _ in router }

        let reply = await edit.applyEdit(siteID: "s1", filePath: "/about", selector: selector, op: "replace-text", value: nil)

        #expect(reply.status == .failed)
    }

    /// Minimal thread-safe box so the provider closure can capture the siteID it saw.
    final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ v: T) { value = v }
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    }
}
