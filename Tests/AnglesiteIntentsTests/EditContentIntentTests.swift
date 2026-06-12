import Testing
import Foundation
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Covers `EditContentIntent` (B.5 / #149) and the new `ContentDialogs.edit*` helpers.
///
/// The intent tests verify that `perform()` (a) decodes the entity's stored selector, (b) builds
/// the right `EditMessage`, and (c) routes it through `IntentEditBridge` for the entity's siteID.
/// Dialog wording is covered exhaustively in the separate `ContentDialogs.edit*` suite below —
/// `IntentResult & ProvidesDialog`'s underlying value is opaque, so reaching into it from a test
/// is fragile; testing the pure dialog helpers directly is the same coverage without that fragility.
extension AppIntentsTests {

    @Suite("EditContentIntent", .serialized)
    struct EditContentIntentTests {
        actor RecordingRouter: EditRouter {
            private(set) var received: [EditMessage] = []
            let reply: EditReply
            init(reply: EditReply) { self.reply = reply }
            func apply(_ message: EditMessage) async -> EditReply {
                received.append(message)
                return reply
            }
        }

        private static func fixture(
            siteID: String = "s1",
            displayName: String = "h1 \u{2014} Welcome",
            pagePath: String = "/about/",
            selectorTag: String = "H1"
        ) -> ElementEntity {
            let selector: JSONValue = .object([
                "tag": .string(selectorTag),
                "classes": .array([]),
                "nthChild": .int(1),
            ])
            return ElementEntity(
                id: ElementEntity.makeID(siteID: siteID, elementID: "v-1"),
                displayName: displayName,
                siteID: siteID,
                selector: ElementEntity.encodeSelector(selector),
                pagePath: pagePath
            )
        }

        private static func bridge(
            router: EditRouter,
            id: String = "fixed"
        ) -> IntentEditBridge {
            IntentEditBridge(routerProvider: { _ in router }, makeID: { id })
        }

        @Test("perform builds an EditMessage from the entity + instruction")
        func perform_buildsEditMessage() async throws {
            let router = RecordingRouter(reply: EditReply(
                id: "fixed", status: .applied, message: nil, file: "src/pages/about.astro"
            ))
            let intent = EditContentIntent()
            intent.element = Self.fixture()
            intent.instruction = "make it bigger"

            try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(router: router)) {
                _ = try await intent.perform()
            }
            let captured = await router.received
            #expect(captured.count == 1)
            let msg = captured[0]
            #expect(msg.path == "/about/")
            #expect(msg.op == EditMessage.Op.applyInstruction)
            #expect(msg.value == .string("make it bigger"))
            guard case .object(let dict) = msg.selector else {
                Issue.record("expected .object selector")
                return
            }
            #expect(dict["tag"] == .string("H1"))
        }

        @Test("perform reaches the bridge for any reply status")
        func perform_routesForAllReplyStatuses() async throws {
            for status: EditReply.Status in [.applied, .failed, .ambiguous] {
                let router = RecordingRouter(reply: EditReply(
                    id: "fixed", status: status, message: "msg"
                ))
                let intent = EditContentIntent()
                intent.element = Self.fixture()
                intent.instruction = "change it"
                try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(router: router)) {
                    _ = try await intent.perform()
                }
                #expect(await router.received.count == 1, "status \(status) didn't reach the router")
            }
        }

        @Test("perform skips the bridge for an unparseable selector")
        func perform_invalidSelectorSkipsBridge() async throws {
            let element = ElementEntity(
                id: "s1:element:v-9",
                displayName: "button \u{2014} Go",
                siteID: "s1",
                selector: "not json at all",
                pagePath: "/contact/"
            )
            let router = RecordingRouter(reply: EditReply(id: "fixed", status: .applied, message: nil))
            let intent = EditContentIntent()
            intent.element = element
            intent.instruction = "submit it"

            try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(router: router)) {
                _ = try await intent.perform()
            }
            #expect(await router.received.isEmpty, "bridge must not be called when selector won't decode")
        }

        @Test("perform routes per the element's siteID, not a global default")
        func perform_routesPerElementSiteID() async throws {
            actor SpyProvider {
                private(set) var lastAsked: String?
                func record(_ siteID: String) { lastAsked = siteID }
            }
            let spy = SpyProvider()
            let stubRouter = RecordingRouter(reply: EditReply(id: "fixed", status: .applied, message: nil))
            let bridge = IntentEditBridge(
                routerProvider: { siteID in
                    await spy.record(siteID)
                    return stubRouter
                },
                makeID: { "fixed" }
            )
            let intent = EditContentIntent()
            intent.element = Self.fixture(siteID: "/Users/x/Sites/beta")
            intent.instruction = "do the thing"

            try await IntentEditBridgeOverride.$scoped.withValue(bridge) {
                _ = try await intent.perform()
            }
            #expect(await spy.lastAsked == "/Users/x/Sites/beta")
        }
    }

    @Suite("ContentDialogs.edit*", .serialized)
    struct ContentEditDialogTests {
        @Test("editApplied: with file") func editApplied_withFile() {
            #expect(ContentDialogs.editApplied(displayName: "h1 \u{2014} Hi", file: "src/pages/about.astro")
                    == "Edited h1 \u{2014} Hi in src/pages/about.astro.")
        }

        @Test("editApplied: without file") func editApplied_withoutFile() {
            #expect(ContentDialogs.editApplied(displayName: "h1 \u{2014} Hi", file: nil)
                    == "Edited h1 \u{2014} Hi.")
            #expect(ContentDialogs.editApplied(displayName: "h1 \u{2014} Hi", file: "")
                    == "Edited h1 \u{2014} Hi.")
        }

        @Test("editFailed: with reason") func editFailed_withReason() {
            #expect(ContentDialogs.editFailed(displayName: "img \u{2014} hero.jpg", reason: "no plugin")
                    == "Couldn’t edit img \u{2014} hero.jpg: no plugin")
        }

        @Test("editFailed: without reason") func editFailed_withoutReason() {
            #expect(ContentDialogs.editFailed(displayName: "img \u{2014} hero.jpg", reason: nil)
                    == "Couldn’t edit img \u{2014} hero.jpg.")
        }

        @Test("editAmbiguous: with detail") func editAmbiguous_withDetail() {
            #expect(ContentDialogs.editAmbiguous(displayName: "button \u{2014} Go", detail: "two matches")
                    == "Not sure how to edit button \u{2014} Go: two matches")
        }

        @Test("editAmbiguous: without detail") func editAmbiguous_withoutDetail() {
            #expect(ContentDialogs.editAmbiguous(displayName: "button \u{2014} Go", detail: nil)
                    == "Not sure how to edit button \u{2014} Go — try rephrasing.")
        }

        @Test("editInvalidSelector") func editInvalidSelector() {
            #expect(ContentDialogs.editInvalidSelector(displayName: "h1 \u{2014} Hi")
                    == "Lost track of h1 \u{2014} Hi — try selecting it again.")
        }

        @Test("editReply dispatches on status") func editReply_dispatchesOnStatus() {
            let applied = EditReply(id: "x", status: .applied, message: nil, file: "f.astro")
            #expect(ContentDialogs.editReply(applied, displayName: "h1")
                    == "Edited h1 in f.astro.")
            let failed = EditReply(id: "x", status: .failed, message: "bad")
            #expect(ContentDialogs.editReply(failed, displayName: "h1")
                    == "Couldn’t edit h1: bad")
            let ambig = EditReply(id: "x", status: .ambiguous, message: "two")
            #expect(ContentDialogs.editReply(ambig, displayName: "h1")
                    == "Not sure how to edit h1: two")
        }
    }
}
