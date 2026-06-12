import Testing
@testable import AnglesiteCore

/// Covers `EditRouterRegistry`'s acceptance criteria: register / unregister / lookup, plus the
/// last-writer-wins overwrite that happens when `PreviewModel.setEditObserver(_:)` rebuilds the
/// router for an already-open site. Tests use a private actor instance (not `.shared`) so they
/// don't bleed across the suite.
struct EditRouterRegistryTests {
    actor StubRouter: EditRouter {
        let label: String
        init(_ label: String) { self.label = label }
        func apply(_ message: EditMessage) async -> EditReply {
            EditReply(id: message.id, status: .applied, message: label)
        }
    }

    @Test("Lookup returns nil for an unregistered siteID")
    func lookup_returnsNilForUnknown() async {
        let registry = EditRouterRegistry()
        let router = await registry.router(for: "missing")
        #expect(router == nil)
    }

    @Test("Register then lookup returns the same router")
    func register_lookup_roundTrips() async {
        let registry = EditRouterRegistry()
        let router = StubRouter("a")
        await registry.register(router, for: "s1")
        let found = await registry.router(for: "s1")
        let reply = await found?.apply(EditMessage(
            id: "x", type: .applyEdit, path: "/", selector: .object([:]), op: "noop", value: nil
        ))
        #expect(reply?.message == "a")
    }

    @Test("Last writer wins on duplicate siteID")
    func register_lastWriterWins() async {
        let registry = EditRouterRegistry()
        await registry.register(StubRouter("first"), for: "s1")
        await registry.register(StubRouter("second"), for: "s1")
        let found = await registry.router(for: "s1")
        let reply = await found?.apply(EditMessage(
            id: "x", type: .applyEdit, path: "/", selector: .object([:]), op: "noop", value: nil
        ))
        #expect(reply?.message == "second")
    }

    @Test("Unregister removes the router")
    func unregister_removes() async {
        let registry = EditRouterRegistry()
        await registry.register(StubRouter("a"), for: "s1")
        await registry.unregister(siteID: "s1")
        let found = await registry.router(for: "s1")
        #expect(found == nil)
    }

    @Test("Unregistering an unknown siteID is a silent no-op")
    func unregister_unknown_silent() async {
        let registry = EditRouterRegistry()
        await registry.unregister(siteID: "missing")
        // No throw, no crash; the registry is just still empty.
        #expect(await registry.knownSiteIDs().isEmpty)
    }

    @Test("knownSiteIDs reflects current registrations across sites")
    func knownSiteIDs_reflectsRegistrations() async {
        let registry = EditRouterRegistry()
        await registry.register(StubRouter("a"), for: "s1")
        await registry.register(StubRouter("b"), for: "s2")
        await registry.register(StubRouter("c"), for: "s3")
        await registry.unregister(siteID: "s2")
        #expect(await registry.knownSiteIDs() == ["s1", "s3"])
    }
}
