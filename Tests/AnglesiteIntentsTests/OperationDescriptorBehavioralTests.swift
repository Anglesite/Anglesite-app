import Testing
import Foundation
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Behavioral agreement for the operation-descriptor registry (#235). Proves each write/edit
/// descriptor maps to a real invoked service call (not a phantom) and that read intents perform no
/// content mutation. Confirmation and the three site-op read/write splits are NOT observable under
/// `swift test` (the seam bypasses `requestConfirmation`; deploy/backup/audit all invoke a command
/// method) — those stay value-asserted in `OperationDescriptorTests`. See the spec for why.
extension AppIntentsTests {
    @Suite("OperationDescriptors.Behavioral", .serialized)
    struct OperationDescriptorBehavioralTests {
        // Content-create routing is asserted with the shared `FakeContentOps`
        // (`Support/FakeContentOps.swift`) via `.pageCalls.count` / `.postCalls.count`.

        /// Records edit-bridge calls.
        actor RoutingRouter: EditRouter {
            private(set) var received = 0
            func apply(_ message: EditMessage) async -> EditReply {
                received += 1
                return EditReply(id: "x", status: .applied, message: nil)
            }
        }

        private static func site() -> SiteEntity {
            SiteEntity(TestStore.site(id: AppIntentsTests.aSite, name: "Alpha"))
        }

        // MARK: Routing agreement — site ops

        @Test("deploy-site routes to the deploy command only")
        func deployRoutes() async throws {
            let fake = FakeOperations()
            let s = TestStore.site(id: AppIntentsTests.aSite, name: "Alpha")
            fake.sites = [s.id: s]
            fake.deployResult = .succeeded(url: URL(string: "https://x.dev")!, duration: 1)
            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = DeploySiteIntent()
                intent.site = SiteEntity(s)
                _ = try await intent.perform()
            }
            #expect(fake.deployCalls.count == 1)
            #expect(fake.backupCalls.isEmpty)
            #expect(fake.auditCalls.isEmpty)
        }

        @Test("backup-site routes to the backup command only")
        func backupRoutes() async throws {
            let fake = FakeOperations()
            let s = TestStore.site(id: AppIntentsTests.aSite, name: "Alpha")
            fake.sites = [s.id: s]
            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = BackupSiteIntent()
                intent.site = SiteEntity(s)
                _ = try await intent.perform()
            }
            #expect(fake.backupCalls.count == 1)
            #expect(fake.deployCalls.isEmpty)
            #expect(fake.auditCalls.isEmpty)
        }

        @Test("audit-site routes to the audit command only")
        func auditRoutes() async throws {
            let fake = FakeOperations()
            let s = TestStore.site(id: AppIntentsTests.aSite, name: "Alpha")
            fake.sites = [s.id: s]
            try await SiteOperationsOverride.$scoped.withValue(fake) {
                var intent = AuditSiteIntent()
                intent.site = SiteEntity(s)
                _ = try await intent.perform()
            }
            #expect(fake.auditCalls.count == 1)
            #expect(fake.deployCalls.isEmpty)
            #expect(fake.backupCalls.isEmpty)
        }

        // MARK: Content-mutation agreement — creates/edit mutate, reads don't

        @Test("add-page routes to createPage (createsContent)")
        func addPageMutates() async throws {
            let fake = FakeContentOps()
            try await ContentOperationsOverride.$scoped.withValue(fake) {
                var intent = AddPageIntent()
                intent.site = Self.site()
                intent.name = "X"
                _ = try await intent.perform()
            }
            #expect(fake.pageCalls.count == 1)
            #expect(fake.postCalls.isEmpty)
        }

        @Test("add-post routes to createPost (createsContent)")
        func addPostMutates() async throws {
            let fake = FakeContentOps()
            try await ContentOperationsOverride.$scoped.withValue(fake) {
                var intent = AddPostIntent()
                intent.site = Self.site()
                intent.title2 = "Hello"
                _ = try await intent.perform()
            }
            #expect(fake.postCalls.count == 1)
            #expect(fake.pageCalls.isEmpty)
        }

        /// Minimal interpreter stub — returns a resolvable text edit so `perform()` advances
        /// past the interpretation step to the bridge.
        private struct PassthroughInterpreter: EditInterpreting {
            func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit {
                InterpretedEdit(kind: .text, newText: "stub", attributeName: nil, attributeValue: nil,
                                styleProperty: nil, styleValue: nil, summary: "stub edit")
            }
        }

        @Test("edit-content routes to the edit bridge (modifiesContent)")
        func editMutates() async throws {
            let router = RoutingRouter()
            let bridge = IntentEditBridge(routerProvider: { _ in router }, makeID: { "x" })
            let selector: JSONValue = .object([
                "tag": .string("H1"),
                "classes": .array([]),
                "nthChild": .int(1),
            ])
            let element = ElementEntity(
                id: ElementEntity.makeID(siteID: AppIntentsTests.aSite, elementID: "v-1"),
                displayName: "h1",
                siteID: AppIntentsTests.aSite,
                selector: ElementEntity.encodeSelector(selector),
                pagePath: "/about/"
            )
            let intent = EditContentIntent()
            intent.element = element
            intent.instruction = "make it bigger"
            try await EditInterpreterOverride.$scoped.withValue(PassthroughInterpreter()) {
                try await IntentEditBridgeOverride.$scoped.withValue(bridge) {
                    _ = try await intent.perform()
                }
            }
            // The dry-run call returns .applied (not .preview), so perform() exits after 1 bridge
            // call — enough to prove the edit-content intent reaches the bridge (modifiesContent).
            #expect(await router.received >= 1)
        }

        @Test("read intents (search, status) perform no content or site mutation")
        func readsDoNotMutate() async throws {
            let createFake = FakeContentOps()
            let siteFake = FakeOperations()
            let graph = SiteContentGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage(route: "/about", title: "About")],
                posts: [],
                images: []
            )
            try await SiteOperationsOverride.$scoped.withValue(siteFake) {
                try await ContentOperationsOverride.$scoped.withValue(createFake) {
                    try await ContentGraphOverride.$scoped.withValue(graph) {
                        var search = SearchContentIntent()
                        search.site = Self.site()
                        search.query = "about"
                        _ = try await search.perform()

                        var status = SiteStatusIntent()
                        status.site = Self.site()
                        _ = try await status.perform()
                    }
                }
            }
            // No content created...
            #expect(createFake.pageCalls.isEmpty)
            #expect(createFake.postCalls.isEmpty)
            // ...and no site op (deploy/backup/audit) accidentally invoked either.
            #expect(siteFake.deployCalls.isEmpty)
            #expect(siteFake.backupCalls.isEmpty)
            #expect(siteFake.auditCalls.isEmpty)
        }
    }
}
