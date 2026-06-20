import Testing
import Foundation
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

// MARK: - Stub interpreters

/// Throws `EditInterpretationError.siteUnavailable` — simulates the element's site not being
/// open in Anglesite (siteID/siteDirectory missing from the entity context).
private struct SiteUnavailableInterpreter: EditInterpreting {
    let reason: String
    func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit {
        throw EditInterpretationError.siteUnavailable(reason)
    }
}

/// Throws `EditInterpretationError.unavailable` — simulates Apple Intelligence missing.
private struct AIUnavailableInterpreter: EditInterpreting {
    func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit {
        throw EditInterpretationError.unavailable("Apple Intelligence not available")
    }
}

// MARK: - Recording router (bridge call spy)

private actor RecordingRouter: EditRouter {
    private(set) var received: [EditMessage] = []
    func apply(_ message: EditMessage) async -> EditReply {
        received.append(message)
        return EditReply(id: "unused", status: .applied, message: nil)
    }
}

// MARK: - Suite

extension AppIntentsTests {

    @Suite("EditContentIntent — interpreter errors", .serialized)
    struct EditContentIntentSiteUnavailableTests {

        private static func fixture(siteID: String = "s1") -> ElementEntity {
            let selector: JSONValue = .object([
                "tag": .string("H1"),
                "classes": .array([]),
                "nthChild": .int(1),
            ])
            return ElementEntity(
                id: ElementEntity.makeID(siteID: siteID, elementID: "v-unavail"),
                displayName: "h1 \u{2014} Welcome",
                siteID: siteID,
                selector: ElementEntity.encodeSelector(selector),
                pagePath: "/about/"
            )
        }

        private static func bridge(router: EditRouter) -> IntentEditBridge {
            IntentEditBridge(routerProvider: { _ in router }, makeID: { "unavail-test" })
        }

        // MARK: Tests

        /// When the interpreter throws `.siteUnavailable`, the dialog must prompt the user to
        /// open the site in Anglesite — NOT the generic "Apple Intelligence" fallback.
        /// The bridge (dry-run and apply) must NOT be called.
        @Test("siteUnavailable: dialog asks user to open site, bridge receives no calls")
        func siteUnavailable_dialogMentionsOpenSite_bridgeNotCalled() async throws {
            let router = RecordingRouter()
            let bridge = Self.bridge(router: router)
            let interp = SiteUnavailableInterpreter(reason: "siteID missing")

            let intent = EditContentIntent()
            intent.element = Self.fixture()
            intent.instruction = "make it bigger"

            let result = try await EditInterpreterOverride.$scoped.withValue(interp) {
                try await IntentEditBridgeOverride.$scoped.withValue(bridge) {
                    try await intent.perform()
                }
            }
            let dialog = "\(result)"
            #expect(dialog.contains("Open this site"),
                    "siteUnavailable must mention opening the site, got: \(dialog)")
            #expect(!dialog.contains("Apple Intelligence"),
                    "siteUnavailable must NOT mention Apple Intelligence, got: \(dialog)")
            #expect(await router.received.isEmpty,
                    "bridge must not be called when interpreter throws siteUnavailable")
        }

        /// When the interpreter throws `.unavailable` (Apple Intelligence missing), the dialog
        /// must mention Apple Intelligence. The bridge must NOT be called.
        @Test("unavailable (AI): dialog mentions Apple Intelligence, bridge receives no calls")
        func aiUnavailable_dialogMentionsAppleIntelligence_bridgeNotCalled() async throws {
            let router = RecordingRouter()
            let bridge = Self.bridge(router: router)
            let interp = AIUnavailableInterpreter()

            let intent = EditContentIntent()
            intent.element = Self.fixture()
            intent.instruction = "change the color to teal"

            let result = try await EditInterpreterOverride.$scoped.withValue(interp) {
                try await IntentEditBridgeOverride.$scoped.withValue(bridge) {
                    try await intent.perform()
                }
            }
            let dialog = "\(result)"
            #expect(dialog.contains("Apple Intelligence"),
                    "AI unavailable must mention Apple Intelligence, got: \(dialog)")
            #expect(await router.received.isEmpty,
                    "bridge must not be called when interpreter throws unavailable")
        }
    }
}
