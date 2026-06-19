import Testing
import Foundation
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

// MARK: - Gate (local to this file)

/// A gate that parks an async task until explicitly released.
/// Uses `CheckedContinuation<Void, Never>` — does NOT check for cancellation —
/// so the parked task stays parked until `release()` is called explicitly.
/// This lets us cancel the surrounding task while `applyEdit` is mid-flight.
private actor EditCancelGate {
    private var cont: CheckedContinuation<Void, Never>?
    private var released = false
    /// True once a waiter has registered its continuation (i.e. the bridge is parked).
    private(set) var parked = false

    func wait() async {
        if released { return }
        parked = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            cont = c
        }
    }

    func release() {
        released = true
        cont?.resume()
        cont = nil
    }
}

// MARK: - GatedRouter

/// Routes through a gate before returning its configured reply — lets us cancel the
/// outer task while `applyEdit` is parked, then release so it returns with a known status.
private actor GatedRouter: EditRouter {
    private let gate: EditCancelGate
    private let reply: EditReply
    init(gate: EditCancelGate, reply: EditReply) {
        self.gate = gate
        self.reply = reply
    }
    func apply(_ message: EditMessage) async -> EditReply {
        await gate.wait()
        return reply
    }
}

// MARK: - Test suite

extension AppIntentsTests {

    @Suite("EditContentIntent cancellation", .serialized)
    struct EditContentIntentCancelTests {

        private static func fixture(siteID: String = "s1") -> ElementEntity {
            let selector: JSONValue = .object([
                "tag": .string("H1"),
                "classes": .array([]),
                "nthChild": .int(1),
            ])
            return ElementEntity(
                id: ElementEntity.makeID(siteID: siteID, elementID: "v-cancel"),
                displayName: "h1 \u{2014} Welcome",
                siteID: siteID,
                selector: ElementEntity.encodeSelector(selector),
                pagePath: "/about/"
            )
        }

        private static func bridge(router: EditRouter) -> IntentEditBridge {
            IntentEditBridge(routerProvider: { _ in router }, makeID: { "cancel-test" })
        }

        /// When the task is cancelled but the bridge reply is `.applied`, `perform()` must
        /// fall through to the normal `ContentDialogs.editReply` path ("Edited …"), not the
        /// cancellation dialog. This verifies Fix 4: `if Task.isCancelled, reply.status != .applied`.
        @Test("cancelled + applied reply: perform() returns editReply dialog, not Canceled")
        func cancelledApplied_showsEditedDialog() async throws {
            let gate = EditCancelGate()
            let appliedReply = EditReply(
                id: "cancel-test",
                status: .applied,
                message: nil,
                file: "src/pages/about.astro"
            )
            let router = GatedRouter(gate: gate, reply: appliedReply)
            let bridge = Self.bridge(router: router)

            let intent = EditContentIntent()
            intent.element = Self.fixture()
            intent.instruction = "make it bigger"

            // Run perform() in a child task so we can cancel it while the bridge is parked.
            let performTask: Task<String, Error> = Task {
                let result = try await IntentEditBridgeOverride.$scoped.withValue(bridge) {
                    try await intent.perform()
                }
                // Extract the dialog text via string interpolation (opaque ProvidesDialog).
                return "\(result)"
            }

            // Yield until the gate is parked, then cancel, then release.
            while !(await gate.parked) { await Task.yield() }
            performTask.cancel()
            await gate.release()

            let dialogDescription = try await performTask.value
            // The normal edit dialog path produces "Edited h1 — Welcome in src/pages/about.astro."
            // The ContentDialogs.editApplied helper is the expected path; verify it's NOT "Canceled".
            #expect(!dialogDescription.lowercased().contains("cancel"),
                    "should not say 'Canceled' when edit was applied, got: \(dialogDescription)")
        }

        /// When the task is cancelled and the bridge reply is NOT `.applied` (e.g. `.failed`),
        /// `perform()` must return the cancellation dialog ("Canceled the edit to …").
        @Test("cancelled + failed reply: perform() returns Canceled dialog")
        func cancelledFailed_showsCanceledDialog() async throws {
            let gate = EditCancelGate()
            let failedReply = EditReply(
                id: "cancel-test",
                status: .failed,
                message: "timed out",
                file: nil
            )
            let router = GatedRouter(gate: gate, reply: failedReply)
            let bridge = Self.bridge(router: router)

            let intent = EditContentIntent()
            intent.element = Self.fixture()
            intent.instruction = "change the color"

            let performTask: Task<String, Error> = Task {
                let result = try await IntentEditBridgeOverride.$scoped.withValue(bridge) {
                    try await intent.perform()
                }
                return "\(result)"
            }

            while !(await gate.parked) { await Task.yield() }
            performTask.cancel()
            await gate.release()

            let dialogDescription = try await performTask.value
            // The cancellation path returns "Canceled the edit to h1 — Welcome."
            #expect(dialogDescription.lowercased().contains("cancel"),
                    "expected 'Canceled …' dialog for failed+cancelled, got: \(dialogDescription)")
        }
    }
}
