import Testing
import Foundation
@testable import AnglesiteIntents

/// Data-level contract tests for the operation-descriptor registry (#235). These assert structure
/// and declared values only; behavioral agreement (routing, content mutation) lives in
/// `OperationDescriptorBehavioralTests`. See the spec for why confirmation and the three site-op
/// side-effects are value-asserted rather than behaviorally cross-checked.
extension AppIntentsTests {
    @Suite("OperationDescriptors")
    struct OperationDescriptorTests {
        @Test("every Siri-phrase intent has a descriptor (coverage anchor)")
        func coverage() {
            let described = Set(AnglesiteOperations.all.map(\.intentTypeName))
            #expect(AnglesiteShortcuts.phraseExposedIntentNames.isSubset(of: described))
        }

        @Test("phrase-exposed name list matches the shortcuts provider count (sync guard)")
        func anchorSync() {
            #expect(AnglesiteShortcuts.appShortcuts.count == AnglesiteShortcuts.phraseExposedIntentNames.count)
        }

        @Test("operationID and intentTypeName are each unique")
        func uniqueness() {
            let ids = AnglesiteOperations.all.map(\.operationID)
            #expect(Set(ids).count == ids.count)
            let names = AnglesiteOperations.all.map(\.intentTypeName)
            #expect(Set(names).count == names.count)
        }

        @Test("descriptor(forIntentTypeName:) resolves a known intent and returns nil otherwise")
        func lookup() {
            #expect(AnglesiteOperations.descriptor(forIntentTypeName: "DeploySiteIntent")?.operationID == "deploy-site")
            #expect(AnglesiteOperations.descriptor(forIntentTypeName: "NotAnIntent") == nil)
        }

        @Test("declared fields match the authoritative value table")
        func declaredFields() throws {
            struct Expected {
                let sideEffect: OperationSideEffect
                let requiresConfirmation: Bool
                let isCancellable: Bool
                let resultShape: OperationResult
            }
            let expected: [String: Expected] = [
                "deploy-site": .init(sideEffect: .publishes, requiresConfirmation: true, isCancellable: true, resultShape: .entity("SiteEntity")),
                "backup-site": .init(sideEffect: .createsContent, requiresConfirmation: false, isCancellable: true, resultShape: .entity("SiteEntity")),
                "audit-site": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: true, resultShape: .entity("SiteEntity")),
                "open-site": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "search-content": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .entities("ContentMatchEntity")),
                "site-status": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "find-content-by-type": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .entities("PostEntity")),
                "preview-site": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "add-page": .init(sideEffect: .createsContent, requiresConfirmation: false, isCancellable: true, resultShape: .entity("PageEntity")),
                "add-post": .init(sideEffect: .createsContent, requiresConfirmation: false, isCancellable: true, resultShape: .entity("PostEntity")),
                // TODO(#239/#250): flip requiresConfirmation to true when the EditContentIntent
                // confirmation gate lands — this assertion passes on stale data until then.
                "edit-content": .init(sideEffect: .modifiesContent, requiresConfirmation: false, isCancellable: true, resultShape: .none),
                "add-booking": .init(sideEffect: .createsContent, requiresConfirmation: true, isCancellable: false, resultShape: .none),
                "add-donations": .init(sideEffect: .createsContent, requiresConfirmation: true, isCancellable: false, resultShape: .none),
                "add-comments": .init(sideEffect: .createsContent, requiresConfirmation: true, isCancellable: false, resultShape: .none),
                "list-dns-records": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "add-dns-record": .init(sideEffect: .createsContent, requiresConfirmation: true, isCancellable: false, resultShape: .none),
                "delete-dns-record": .init(sideEffect: .modifiesContent, requiresConfirmation: true, isCancellable: false, resultShape: .none),
            ]
            #expect(expected.count == AnglesiteOperations.all.count)
            for descriptor in AnglesiteOperations.all {
                let want = try #require(expected[descriptor.operationID], "no expectation for \(descriptor.operationID)")
                #expect(descriptor.sideEffect == want.sideEffect, "\(descriptor.operationID) sideEffect")
                #expect(descriptor.requiresConfirmation == want.requiresConfirmation, "\(descriptor.operationID) requiresConfirmation")
                #expect(descriptor.isCancellable == want.isCancellable, "\(descriptor.operationID) isCancellable")
                #expect(descriptor.resultShape == want.resultShape, "\(descriptor.operationID) resultShape")
            }
        }

        @Test("mcpToolName can be set on a descriptor (forward-looking field)")
        func mcpToolNameIsSettable() {
            let d = OperationDescriptor(
                operationID: "x", displayName: "X", intentTypeName: "XIntent",
                sideEffect: .readOnly, requiresConfirmation: false,
                isCancellable: false, resultShape: .none, mcpToolName: "x_tool"
            )
            #expect(d.mcpToolName == "x_tool")
        }
    }
}
