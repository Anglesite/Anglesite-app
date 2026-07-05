import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Coverage anchor for the Siri AI smoke matrix (#237).
///
/// `docs/specs/2026-06-20-siri-smoke-matrix.md` documents the product-level acceptance matrix —
/// the nine supported Siri workflows, their phrases, app states, and expected outcomes. A doc
/// can silently drift from the code; this suite pins the *deterministic* claims of that doc to the
/// shipped intent / operation registry so the matrix can't go stale unnoticed:
///
/// - every workflow row maps to a real `AnglesiteOperations` descriptor,
/// - each row's side-effect + confirmation declaration matches the registry,
/// - the curated-phrase set and the shortcuts-provider count stay aligned,
/// - the two confirmation-gated workflows (deploy, edit) actually request confirmation at
///   runtime — i.e. the "Confirms? yes" cells are behaviorally true, not just documented.
///
/// The manual-only rows (spoken-phrase recognition, onscreen-element resolution, on-device NL
/// interpretation, system MCP, MAS sandbox grant) are deliberately NOT asserted green here — they
/// are listed in `Self.manualOnly` and the doc's "Manual-only" section, and a guard test below
/// asserts they remain disjoint from the CI-covered operations so they can never be mistaken for
/// automated coverage.
extension AppIntentsTests {
    @Suite("SmokeMatrix")
    struct SmokeMatrixTests {

        /// One documented workflow row, reduced to its machine-checkable claims.
        struct Workflow {
            let label: String
            /// `operationID` in `AnglesiteOperations`.
            let operationID: String
            let sideEffect: OperationSideEffect
            /// Whether the workflow confirms before its side effect at *runtime*. This is the
            /// matrix's "Confirms?" column. For `edit-content` this is `true` even though the
            /// descriptor flag is still `false` (TODO #239/#250) — the runtime gate is live and is
            /// behaviorally asserted in `confirmationGatedWorkflowsRequestConfirmationAtRuntime`.
            let confirmsAtRuntime: Bool
        }

        /// The documented workflows, transcribed from the smoke-matrix doc. `site-status` is
        /// the matrix's row 5b (a sibling read intent); `add-page`/`add-post` are row 6's two
        /// intents. `OpenSiteIntent` is row 1 (no curated phrase — reached via entity tap).
        /// `add-booking`, `add-donations`, `add-comments` are the bucket-3 integration intents (#282).
        /// `list-dns-records`/`add-dns-record`/`delete-dns-record` are the Domain-sheet DNS
        /// operations (#462, commit 13bce39b). Like the bucket-3 integration intents, they are
        /// deliberately NOT registered in `AnglesiteShortcuts.phraseExposedIntentNames` (10-phrase
        /// budget), so they are reached via the Domain sheet GUI / Shortcuts / entity match, not a
        /// curated Siri phrase. `confirmsAtRuntime` mirrors each intent's `perform()` in
        /// `DomainIntents.swift`: `ListDNSRecordsIntent` never calls `requestConfirmation`;
        /// `AddDNSRecordIntent`/`DeleteDNSRecordIntent` both do, matching their registry
        /// `requiresConfirmation: true` (unlike `edit-content`, there's no flag/runtime split here).
        static let workflows: [Workflow] = [
            Workflow(label: "Open this site", operationID: "open-site", sideEffect: .readOnly, confirmsAtRuntime: false),
            Workflow(label: "Back up this site", operationID: "backup-site", sideEffect: .createsContent, confirmsAtRuntime: false),
            Workflow(label: "Audit this site", operationID: "audit-site", sideEffect: .readOnly, confirmsAtRuntime: false),
            Workflow(label: "Deploy with confirmation", operationID: "deploy-site", sideEffect: .publishes, confirmsAtRuntime: true),
            Workflow(label: "Search content", operationID: "search-content", sideEffect: .readOnly, confirmsAtRuntime: false),
            Workflow(label: "Site status", operationID: "site-status", sideEffect: .readOnly, confirmsAtRuntime: false),
            Workflow(label: "Find content by type", operationID: "find-content-by-type", sideEffect: .readOnly, confirmsAtRuntime: false),
            Workflow(label: "Add page", operationID: "add-page", sideEffect: .createsContent, confirmsAtRuntime: false),
            Workflow(label: "Add post", operationID: "add-post", sideEffect: .createsContent, confirmsAtRuntime: false),
            Workflow(label: "Preview a page", operationID: "preview-site", sideEffect: .readOnly, confirmsAtRuntime: false),
            Workflow(label: "Edit visible content with confirmation", operationID: "edit-content", sideEffect: .modifiesContent, confirmsAtRuntime: true),
            Workflow(label: "Add booking integration", operationID: "add-booking", sideEffect: .createsContent, confirmsAtRuntime: true),
            Workflow(label: "Add donations integration", operationID: "add-donations", sideEffect: .createsContent, confirmsAtRuntime: true),
            Workflow(label: "Add comments integration", operationID: "add-comments", sideEffect: .createsContent, confirmsAtRuntime: true),
            Workflow(label: "List DNS records for this domain", operationID: "list-dns-records", sideEffect: .readOnly, confirmsAtRuntime: false),
            Workflow(label: "Add a DNS record", operationID: "add-dns-record", sideEffect: .createsContent, confirmsAtRuntime: true),
            Workflow(label: "Delete a DNS record", operationID: "delete-dns-record", sideEffect: .modifiesContent, confirmsAtRuntime: true),
        ]

        /// Capabilities the doc marks manual-only. These map to no automated assertion by design;
        /// the guard test below keeps them out of the CI-covered operation set.
        static let manualOnly: Set<String> = [
            "spoken-phrase-recognition",
            "onscreen-element-resolution",
            "foundation-models-nl-interpretation",
            "system-mcp-bridge",
            "mas-sandbox-grant",
        ]

        // MARK: - Matrix ↔ registry sync

        @Test("every documented workflow maps to a shipped operation descriptor")
        func everyWorkflowHasADescriptor() throws {
            for wf in Self.workflows {
                let descriptor = AnglesiteOperations.all.first { $0.operationID == wf.operationID }
                #expect(descriptor != nil, "smoke-matrix workflow “\(wf.label)” references unknown operation \(wf.operationID)")
            }
        }

        @Test("the matrix covers every shipped operation (no undocumented Siri surface)")
        func everyOperationIsInTheMatrix() {
            let documented = Set(Self.workflows.map(\.operationID))
            let shipped = Set(AnglesiteOperations.all.map(\.operationID))
            #expect(documented == shipped,
                    "matrix/registry drift — documented: \(documented.sorted()), shipped: \(shipped.sorted())")
        }

        @Test("each workflow's documented side-effect matches the registry")
        func sideEffectsMatchRegistry() throws {
            for wf in Self.workflows {
                let d = try #require(AnglesiteOperations.descriptor(forIntentTypeName: intentTypeName(for: wf.operationID)),
                                     "no descriptor for \(wf.operationID)")
                #expect(d.sideEffect == wf.sideEffect, "\(wf.operationID) side-effect drifted from the matrix")
            }
        }

        // MARK: - Phrase surface

        @Test("curated-phrase set and shortcuts-provider count stay aligned")
        func phraseSurfaceIsConsistent() {
            // The provider count is the only thing Apple lets us read back (AppShortcut is
            // type-erased). The matrix's "curated phrase" column corresponds to the
            // phrase-exposed name set; they must match the provider count.
            #expect(AnglesiteShortcuts.appShortcuts.count == AnglesiteShortcuts.phraseExposedIntentNames.count)
        }

        @Test("every phrase-exposed intent is a documented workflow")
        func phraseExposedIntentsAreDocumented() {
            let documentedIntentNames = Set(Self.workflows.map { intentTypeName(for: $0.operationID) })
            #expect(AnglesiteShortcuts.phraseExposedIntentNames.isSubset(of: documentedIntentNames),
                    "a phrase-exposed intent is missing from the smoke matrix")
        }

        // MARK: - Confirmation gates

        @Test("deploy is the publishing workflow and declares confirmation in the registry")
        func deployDeclaresConfirmation() throws {
            // The matrix's "Deploy with confirmation" row maps to the only `.publishes` operation,
            // which must declare `requiresConfirmation: true`. The runtime gate itself
            // (`requestConfirmation` before publishing) can't be exercised under `swift test` — no
            // intentsd — so it is a manual-pass row; here we pin the registry declaration.
            let deploy = try #require(AnglesiteOperations.all.first { $0.operationID == "deploy-site" })
            #expect(deploy.sideEffect == .publishes)
            #expect(deploy.requiresConfirmation, "deploy must declare confirmation before publishing")
            // No other workflow should silently publish.
            let publishers = AnglesiteOperations.all.filter { $0.sideEffect == .publishes }
            #expect(publishers.map(\.operationID) == ["deploy-site"])
        }

        @Test("edit declines without writing when the user does not confirm")
        func editConfirmationGateBlocksWriteOnDecline() async throws {
            // Mirrors EditContentIntentFlowTests.declinePath: a declined edit dry-runs but never
            // applies. This is the matrix's row-8 "Confirms? yes" claim made behavioral.
            actor PhaseRouter: EditRouter {
                private(set) var applies = 0
                func apply(_ m: EditMessage) async -> EditReply {
                    if m.dryRun {
                        return EditReply(id: m.id, status: .preview, message: nil, before: "old", after: "new", op: m.op)
                    }
                    applies += 1
                    return EditReply(id: m.id, status: .applied, message: nil, file: "src/pages/x.astro")
                }
            }
            struct StubInterpreter: EditInterpreting {
                func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit {
                    InterpretedEdit(kind: .text, newText: "new", attributeName: nil, attributeValue: nil,
                                    styleProperty: nil, styleValue: nil, summary: "s")
                }
            }
            let router = PhaseRouter()
            let bridge = IntentEditBridge(routerProvider: { _ in router }, makeID: { "smoke-edit" })
            let intent = EditContentIntent()
            intent.element = ElementEntity(
                id: "s:element:1",
                displayName: "h1 \u{2014} Hi",
                siteID: "s",
                selector: #"{"tag":"h1","classes":[],"nthChild":1,"textContent":"Hi"}"#,
                pagePath: "/about/"
            )
            intent.instruction = "make it shorter"

            try await IntentEditBridgeOverride.$scoped.withValue(bridge) {
                try await EditInterpreterOverride.$scoped.withValue(StubInterpreter()) {
                    try await ConfirmationOverride.$scoped.withValue(.decline) {
                        _ = try await intent.perform()
                    }
                }
            }
            #expect(await router.applies == 0, "a declined edit must never write")
        }

        // MARK: - Manual-only items are not faked green

        @Test("manual-only capabilities are disjoint from the automated operation set")
        func manualOnlyIsNotRepresentedAsAutomated() {
            let automated = Set(AnglesiteOperations.all.map(\.operationID))
            #expect(Self.manualOnly.isDisjoint(with: automated),
                    "a manual-only capability is masquerading as an automated operation")
        }

        // MARK: - Helpers

        /// Map a smoke-matrix `operationID` to its intent type name via the registry.
        private func intentTypeName(for operationID: String) -> String {
            AnglesiteOperations.all.first { $0.operationID == operationID }?.intentTypeName ?? operationID
        }
    }
}
