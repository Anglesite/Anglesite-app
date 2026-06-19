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
///
/// `parkedSignal` yields exactly once when a waiter registers its continuation, so the test can
/// `await` the parked state instead of spin-polling a flag with `Task.yield()` — the same
/// AsyncStream signalling pattern `MCPClientCancellationTests` uses to avoid a hang risk if the
/// awaited point is never reached.
private actor EditCancelGate {
    private var cont: CheckedContinuation<Void, Never>?
    private var released = false

    nonisolated let parkedSignal: AsyncStream<Void>
    private let parkedContinuation: AsyncStream<Void>.Continuation

    init() {
        var c: AsyncStream<Void>.Continuation!
        parkedSignal = AsyncStream { c = $0 }
        parkedContinuation = c
    }

    func wait() async {
        if released { return }
        parkedContinuation.yield(())   // announce the parked state, then suspend
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

// MARK: - Routers

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

/// Returns its reply without gating — for cases that don't need to cancel mid-flight.
private actor ImmediateRouter: EditRouter {
    private let reply: EditReply
    init(reply: EditReply) { self.reply = reply }
    func apply(_ message: EditMessage) async -> EditReply { reply }
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

        /// Runs `perform()` in a child task, cancels it once the router has parked, then releases
        /// the gate so the router returns `reply`. Returns the dialog's string description.
        private static func performCancellingMidFlight(reply: EditReply) async throws -> String {
            let gate = EditCancelGate()
            let router = GatedRouter(gate: gate, reply: reply)
            let bridge = Self.bridge(router: router)

            let intent = EditContentIntent()
            intent.element = Self.fixture()
            intent.instruction = "make it bigger"

            let performTask: Task<String, Error> = Task {
                let result = try await IntentEditBridgeOverride.$scoped.withValue(bridge) {
                    try await intent.perform()
                }
                return "\(result)"  // opaque ProvidesDialog — interpolate to read the dialog text
            }

            // Await the parked signal (no spin-poll), then cancel mid-flight and release.
            var parked = gate.parkedSignal.makeAsyncIterator()
            _ = await parked.next()
            performTask.cancel()
            await gate.release()

            return try await performTask.value
        }

        /// A genuine plugin failure that *coincides* with cancellation must surface the real error,
        /// not be mislabelled "Canceled". The reply carries the actual failure message ("timed out"),
        /// which is not the router's "canceled" sentinel — so `perform()` keys off the reply, not
        /// `Task.isCancelled`, and reports the error.
        @Test("genuine failure during cancellation: surfaces the error, not 'Canceled'")
        func genuineFailureDuringCancellation_surfacesError() async throws {
            let failedReply = EditReply(id: "cancel-test", status: .failed, message: "timed out", file: nil)
            let dialog = try await Self.performCancellingMidFlight(reply: failedReply)
            #expect(dialog.contains("timed out"), "should surface the real failure message, got: \(dialog)")
            #expect(!dialog.lowercased().contains("cancel"),
                    "must not mislabel a genuine failure as 'Canceled', got: \(dialog)")
        }

        /// An actual cancellation is self-describing: `MCPApplyEditRouter` maps it to a `.failed`
        /// reply whose message is exactly "canceled". `perform()` recognises that and shows the
        /// cancellation dialog.
        @Test("canceled reply: perform() returns the Canceled dialog")
        func canceledReply_showsCanceledDialog() async {
            let canceledReply = EditReply(id: "cancel-test", status: .failed, message: "canceled", file: nil)
            let bridge = Self.bridge(router: ImmediateRouter(reply: canceledReply))

            let intent = EditContentIntent()
            intent.element = Self.fixture()
            intent.instruction = "change the color"

            let dialog = await IntentEditBridgeOverride.$scoped.withValue(bridge) {
                "\((try? await intent.perform()) as Any)"
            }
            #expect(dialog.lowercased().contains("cancel"),
                    "a 'canceled' reply should produce the Canceled dialog, got: \(dialog)")
        }

        /// An `.applied` reply wins even if the task was cancelled mid-flight: the edit landed, so
        /// the user sees "Edited …", never "Canceled".
        @Test("cancelled + applied reply: returns the Edited dialog, not Canceled")
        func cancelledApplied_showsEditedDialog() async throws {
            let appliedReply = EditReply(id: "cancel-test", status: .applied, message: nil, file: "src/pages/about.astro")
            let dialog = try await Self.performCancellingMidFlight(reply: appliedReply)
            #expect(!dialog.lowercased().contains("cancel"),
                    "an applied edit should never read as 'Canceled', got: \(dialog)")
        }
    }
}
