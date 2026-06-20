import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteIntents

@Suite("EditContentIntent interpret→dry-run→confirm→apply")
struct EditContentIntentFlowTests {
    // Router that returns a preview for dry-run calls and an applied reply for real calls,
    // recording each so tests can assert how many of each happened.
    actor PhaseRouter: EditRouter {
        private(set) var dryRuns = 0
        private(set) var applies = 0
        func apply(_ m: EditMessage) async -> EditReply {
            if m.dryRun {
                dryRuns += 1
                return EditReply(id: m.id, status: .preview, message: nil, before: "old", after: "new", op: m.op)
            }
            applies += 1
            return EditReply(id: m.id, status: .applied, message: nil, file: "src/pages/about.astro")
        }
    }

    struct StubInterpreter: EditInterpreting {
        let edit: InterpretedEdit
        func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit {
            edit
        }
    }

    struct FailingInterpreter: EditInterpreting {
        func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit {
            throw EditInterpretationError.unavailable("no AI")
        }
    }

    static func textEdit() -> InterpretedEdit {
        InterpretedEdit(kind: .text, newText: "new", attributeName: nil, attributeValue: nil,
                        styleProperty: nil, styleValue: nil, summary: "s")
    }

    static func fixtureIntent() -> EditContentIntent {
        let i = EditContentIntent()
        i.element = ElementEntity(
            id: "s:element:1",
            displayName: "h1 \u{2014} Hi",
            siteID: "s",
            selector: #"{"tag":"h1","classes":[],"nthChild":1,"textContent":"Hi"}"#,
            pagePath: "/about/"
        )
        i.instruction = "make it shorter"
        return i
    }

    static func bridge(_ router: EditRouter) -> IntentEditBridge {
        IntentEditBridge(routerProvider: { _ in router }, makeID: { "fixed" })
    }

    @Test("confirm path: one dry-run then one apply")
    func confirmPath() async throws {
        let r = PhaseRouter()
        try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(r)) {
            try await EditInterpreterOverride.$scoped.withValue(StubInterpreter(edit: Self.textEdit())) {
                try await ConfirmationOverride.$scoped.withValue(.confirm) {
                    _ = try await Self.fixtureIntent().perform()
                }
            }
        }
        #expect(await r.dryRuns == 1)
        #expect(await r.applies == 1)
    }

    @Test("decline path: dry-run happens, apply never does")
    func declinePath() async throws {
        let r = PhaseRouter()
        try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(r)) {
            try await EditInterpreterOverride.$scoped.withValue(StubInterpreter(edit: Self.textEdit())) {
                try await ConfirmationOverride.$scoped.withValue(.decline) {
                    _ = try await Self.fixtureIntent().perform()
                }
            }
        }
        #expect(await r.dryRuns == 1)
        #expect(await r.applies == 0, "a declined edit must never apply")
    }

    @Test("unavailable interpreter: graceful dialog, zero router calls")
    func unavailable() async throws {
        let r = PhaseRouter()
        try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(r)) {
            try await EditInterpreterOverride.$scoped.withValue(FailingInterpreter()) {
                try await ConfirmationOverride.$scoped.withValue(.confirm) {
                    _ = try await Self.fixtureIntent().perform()
                }
            }
        }
        #expect(await r.dryRuns == 0)
        #expect(await r.applies == 0)
    }

    @Test("dry-run refusal: relayed, no apply")
    func dryRunRefusal() async throws {
        actor RefusingRouter: EditRouter {
            private(set) var applies = 0
            func apply(_ m: EditMessage) async -> EditReply {
                if m.dryRun { return EditReply(id: m.id, status: .failed, message: "no-match") }
                applies += 1
                return EditReply(id: m.id, status: .applied, message: nil)
            }
        }
        let r = RefusingRouter()
        try await IntentEditBridgeOverride.$scoped.withValue(Self.bridge(r)) {
            try await EditInterpreterOverride.$scoped.withValue(StubInterpreter(edit: Self.textEdit())) {
                try await ConfirmationOverride.$scoped.withValue(.confirm) {
                    _ = try await Self.fixtureIntent().perform()
                }
            }
        }
        #expect(await r.applies == 0, "a refused dry-run must not apply")
    }
}
